import AppKit
import CoreVideo
import MirrorCore
import QuartzCore
import os

enum MirrorState: Equatable {
    case starting
    /// Advertising and waiting for a sender to pick the receiver called `receiverName`.
    case waiting(receiverName: String)
    /// Other devices cannot see the receiver, most likely because macOS has not allowed local network access.
    case needsLocalNetwork
    case live(sender: String)
    case failed(String)
}

/// Runs the AirPlay receiver, decodes the video it receives and hands over the pictures.
final class MirrorSession {
    /// Called on the main thread.
    var onStateChange: ((MirrorState) -> Void)?
    /// Called on the main thread with the newest decoded picture. Older ones that were not shown yet are skipped.
    var onPicture: ((CVPixelBuffer) -> Void)?
    /// Called on the main thread with the picture's width divided by its height.
    var onAspect: ((CGFloat) -> Void)?
    var onSenderActivity: ((TimeInterval) -> Void)?

    private let settings: ReceiverSettings
    /// Serial across sessions so renaming cannot publish two receivers with the same identity.
    private static let listenerQueue = DispatchQueue(label: "com.eitan.AirPlayViewer.listener", qos: .userInitiated)
    private var receiver: AirPlayReceiver? // listenerQueue only
    // Main thread only.
    private var listenerEpoch: UInt64 = 0
    private var listening = false
    private var senderName: String?
    private var requestedAt: TimeInterval?
    private var displayedGeneration: UInt64?
    private var pictureSize = CGSize.zero
    /// The name other devices list this receiver under; Bonjour may add a number to avoid a clash.
    private var advertisedName: String
    private var probe: AdvertisementProbe?
    private var failedChecks = 0

    private let videoQueue = DispatchQueue(label: "com.eitan.AirPlayViewer.video", qos: .userInteractive)
    // Used only on `videoQueue`.
    private let decoder = VideoDecoder()
    private var decoderGeneration: UInt64?
    private var statistics = StreamStatistics(interval: 5)
    private var frameActivity = FrameActivity()
    private var activityEpoch: UInt64?

    // Shared by input callbacks, decode and display. Never hold during decode or UI callbacks.
    private let streamLock = NSCondition()
    private var generation: UInt64 = 0
    private var mirrorStarted = false
    private var backlog = VideoBacklog.forLiveMirroring()
    private var draining = false
    private var lastDropLog: TimeInterval?
    private var pendingPicture: CVPixelBuffer?
    private var deliveryGeneration: UInt64?
    private var activityEnabled = false
    private var activityRevision: UInt64 = 0

    private static let log = Logger(subsystem: "com.eitan.AirPlayViewer", category: "mirror")
    private static let protocolLog = Logger(subsystem: "com.eitan.AirPlayViewer", category: "airplay")

    init(settings: ReceiverSettings) {
        self.settings = settings
        self.advertisedName = settings.name
    }

    var isMirroring: Bool { streamLock.withLock { mirrorStarted } }

    /// Starts the receiver. Call on the main thread.
    func start() {
        onStateChange?(.starting)
        startReceiver()
    }

    /// Stops the receiver. Call on the main thread.
    func stop() {
        listenerEpoch &+= 1
        listening = false
        probe?.cancel()
        probe = nil
        Self.listenerQueue.async { [self] in
            receiver?.stop()
            receiver = nil
        }
        endPicture(mirrorEnded: true)
    }

    static func finishStopping() { listenerQueue.sync {} }

    func setPresentationEnabled(_ enabled: Bool) {
        streamLock.withLock {
            guard activityEnabled != enabled else { return }
            activityEnabled = enabled
            activityRevision &+= 1
        }
    }

    /// Takes one Annex B packet from the receiver (or from the diagnostic pattern). Any thread.
    func ingest(_ data: Data, codec: VideoCodec, captureTime: UInt64) {
        let inputGeneration = streamLock.withLock { generation }
        guard let packet = VideoPacketParser.parse(data, codec: codec) else { return }
        let frame = VideoBacklog.Frame(packet: packet, codec: codec, captureTime: captureTime, bytes: data.count)
        let dropped = streamLock.withLock {
            // Preserve compressed reference frames. Waiting briefly here lets TCP slow the sender
            // while the decoder catches up. Bound the wait so protocol teardown cannot hang.
            let deadline = Date().addingTimeInterval(0.2)
            while generation == inputGeneration, backlog.shouldWaitForSpace(for: frame) {
                guard streamLock.wait(until: deadline) else { break }
            }
            guard generation == inputGeneration else { return 0 }
            let dropped = backlog.append(frame, at: CACurrentMediaTime())
            if !backlog.isEmpty { scheduleDrainLocked() }
            guard dropped > 0 else { return 0 }
            let uptime = ProcessInfo.processInfo.systemUptime
            guard lastDropLog.map({ uptime - $0 >= 5 }) ?? true else { return 0 }
            lastDropLog = uptime
            return dropped
        }
        if dropped > 0 {
            Self.log.notice("discarded \(dropped) queued or dependent video frames")
        }
    }

    // MARK: Receiver (main thread)

    private func startReceiver() {
        listenerEpoch &+= 1
        let epoch = listenerEpoch
        Self.listenerQueue.async { [weak self] in
            guard let self else { return }
            self.receiver?.stop()
            self.receiver = nil
            let result = Result { try self.makeReceiver() }
            if case .success(let receiver) = result { self.receiver = receiver }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.listenerEpoch == epoch else { return }
                switch result {
                case .success:
                    self.listening = true
                    if self.displayedGeneration == nil { self.onStateChange?(.waiting(receiverName: self.advertisedName)) }
                    self.checkAdvertisement()
                case .failure(AirPlayReceiver.StartError.failed(let step)):
                    Self.log.error("receiver failed to start at step \(step)")
                    self.onStateChange?(.failed(L10n.receiverFailedHint(code: step)))
                case .failure(let error):
                    Self.log.error("receiver failed to start: \(error.localizedDescription, privacy: .public)")
                    self.onStateChange?(.failed(error.localizedDescription))
                }
            }
        }
    }

    private func makeReceiver() throws -> AirPlayReceiver {
        var events = AirPlayReceiver.Events()
        events.clientRequested = { [weak self] name, model in
            Self.log.info("sender asked to connect: \(name, privacy: .public) (\(model, privacy: .public))")
            let time = CACurrentMediaTime()
            DispatchQueue.main.async {
                self?.senderName = name.isEmpty ? nil : name
                self?.requestedAt = time
            }
        }
        events.mirroringChanged = { [weak self] running in
            Self.log.info("mirroring \(running ? "started" : "ended", privacy: .public)")
            guard let self else { return }
            if running {
                self.streamLock.withLock { self.mirrorStarted = true }
            } else {
                self.endPicture(mirrorEnded: true)
            }
        }
        events.videoFormat = { codec, width, height in
            Self.log.info("video \(codec == .hevc ? "HEVC" : "H.264", privacy: .public) \(width)x\(height)")
        }
        events.videoPacket = { [weak self] data, codec, captureTime in
            self?.ingest(data, codec: codec, captureTime: captureTime)
        }
        events.videoReset = { [weak self] in
            Self.log.info("video reset")
            self?.endPicture()
        }
        events.log = { level, message in
            // The protocol library's own messages: errors and warnings stand out, the rest is for diagnosis.
            if level <= 3 {
                Self.protocolLog.error("\(message, privacy: .public)")
            } else if level <= 5 {
                Self.protocolLog.notice("\(message, privacy: .public)")
            } else {
                Self.protocolLog.info("\(message, privacy: .public)")
            }
        }

        let configuration = AirPlayReceiver.Configuration(
            name: settings.name, deviceID: settings.deviceID, keyFile: Self.keyFile(),
            allowHEVC: settings.allowHEVC, width: settings.width, height: settings.height, maxFPS: settings.maxFPS)
        let receiver = try AirPlayReceiver(configuration: configuration, events: events)
        Self.log.info("receiver on port \(receiver.port), max \(self.settings.width)x\(self.settings.height)@\(self.settings.maxFPS)")
        return receiver
    }

    /// Looks for this receiver on the network, as a sender would, until it is found.
    private func checkAdvertisement() {
        guard listening, probe == nil else { return }
        probe = AdvertisementProbe(deviceID: settings.deviceID, timeout: 3) { [weak self] status in
            self?.handle(status)
        }
    }

    private func handle(_ status: AdvertisementStatus) {
        probe = nil
        guard listening else { return }
        switch status {
        case .visible(let name):
            Self.log.info("advertised as \"\(name, privacy: .public)\"")
            failedChecks = 0
            advertisedName = name
            if displayedGeneration == nil { onStateChange?(.waiting(receiverName: name)) }
        case .blocked, .hidden:
            failedChecks += 1
            Self.log.notice("""
                not visible on the network: \(status == .blocked ? "local network access denied" : "not listed", privacy: .public) \
                (check \(self.failedChecks))
                """)
            guard displayedGeneration == nil, !streamLock.withLock({ mirrorStarted }) else { return }
            onStateChange?(.needsLocalNetwork)
            // A registration made while access was denied may never be published; make a new one now and then.
            if status == .hidden, failedChecks % 2 == 0 {
                listening = false
                startReceiver()
                return
            }
            let epoch = listenerEpoch
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.listenerEpoch == epoch else { return }
                self.checkAdvertisement()
            }
        }
    }

    // MARK: Video queue

    private func scheduleDrainLocked() {
        guard !draining else { return }
        draining = true
        videoQueue.async { [weak self] in self?.drainVideo() }
    }

    private func drainVideo() {
        while true {
            let (current, frame) = streamLock.withLock {
                let frame = backlog.popFirst()
                if frame == nil { draining = false }
                else { streamLock.signal() }
                return (generation, frame)
            }
            if decoderGeneration != current {
                decoderGeneration = current
                statistics.reset()
                frameActivity = FrameActivity()
                decoder.reset()
            } else if frame?.restartDecoder == true {
                decoder.resumeAtKeyFrame()
            }
            guard let frame else { return }
            decode(frame, generation: current)
        }
    }

    private func decode(_ frame: VideoBacklog.Frame, generation: UInt64) {
        let picture: CVPixelBuffer
        do {
            guard let decoded = try decoder.decode(frame.packet, codec: frame.codec) else { return }
            picture = decoded
        } catch {
            // The decoder starts again by itself at the next key frame.
            Self.log.error("could not decode a frame: \(String(describing: error), privacy: .public)")
            return
        }
        deliver(picture, generation: generation)
        let (enabled, revision) = streamLock.withLock { (activityEnabled, activityRevision) }
        if enabled {
            if activityEpoch != revision {
                frameActivity = FrameActivity()
                activityEpoch = revision
            }
            let time = CACurrentMediaTime()
            if frameActivity.record(picture, at: time) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.streamLock.withLock({ self.generation == generation && self.activityRevision == revision }) else { return }
                    self.onSenderActivity?(time)
                }
            }
        }
        // Age: from the sender capturing the frame to this Mac having decoded it.
        let now = AirPlayReceiver.now()
        let age: UInt64? = frame.captureTime > 0 && now > frame.captureTime ? now - frame.captureTime : nil
        if let report = statistics.record(bytes: frame.bytes, ageNanoseconds: age, at: ProcessInfo.processInfo.systemUptime) {
            let mean = report.meanAgeMilliseconds.map { String(format: "%.0f", $0) } ?? "-"
            let peak = report.maxAgeMilliseconds.map { String(format: "%.0f", $0) } ?? "-"
            Self.log.notice("""
                frames fps=\(report.framesPerSecond, format: .fixed(precision: 1)) \
                kbps=\(report.kilobitsPerSecond, format: .fixed(precision: 0)) \
                age_ms mean=\(mean, privacy: .public) max=\(peak, privacy: .public)
                """)
        }
    }

    /// Hands the picture to the main thread. If the main thread is busy, only the newest picture is kept.
    private func deliver(_ picture: CVPixelBuffer, generation: UInt64) {
        let schedule = streamLock.withLock {
            guard self.generation == generation else { return false }
            pendingPicture = picture
            guard deliveryGeneration != generation else { return false }
            deliveryGeneration = generation
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let newest = self.streamLock.withLock { () -> CVPixelBuffer? in
                guard self.generation == generation else { return nil }
                defer {
                    self.pendingPicture = nil
                    self.deliveryGeneration = nil
                }
                return self.pendingPicture
            }
            guard let newest else { return }
            let size = CVImageBufferGetDisplaySize(newest)
            if size != self.pictureSize, size.width > 0, size.height > 0 {
                self.pictureSize = size
                self.onAspect?(size.width / size.height)
            }
            self.onPicture?(newest)
            if self.displayedGeneration != generation {
                self.displayedGeneration = generation
                if let requestedAt = self.requestedAt {
                    let elapsed = (CACurrentMediaTime() - requestedAt) * 1000
                    Self.log.notice("setup_to_picture_ms=\(elapsed, format: .fixed(precision: 1))")
                    self.requestedAt = nil
                }
                self.onStateChange?(.live(sender: self.senderName ?? L10n.unknownSender))
            }
        }
    }

    /// Reset the decoder, holding the last picture until recovery or a real disconnect. Any thread.
    private func endPicture(mirrorEnded: Bool = false) {
        streamLock.withLock {
            if mirrorEnded { mirrorStarted = false }
            generation &+= 1
            backlog.clear()
            streamLock.broadcast()
            pendingPicture = nil
            deliveryGeneration = nil
            lastDropLog = nil
            scheduleDrainLocked()
            guard mirrorEnded else { return }
            // A later decoder reset must not discard this transition. The queue order puts it
            // before any picture from the next stream.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.displayedGeneration != nil || self.listening else { return }
                self.displayedGeneration = nil
                self.pictureSize = .zero
                self.senderName = nil
                self.requestedAt = nil
                self.onStateChange?(.waiting(receiverName: self.advertisedName))
            }
        }
    }

    /// Where the receiver's key pair is kept, so senders recognise it after a relaunch.
    private static func keyFile() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        do {
            return try AppIdentity.receiverKey(in: support)
        } catch {
            log.error("could not prepare receiver identity: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
