import CAirPlay
import Foundation

/// An AirPlay screen-mirroring receiver: advertises itself on the local network and hands over the video a sender mirrors.
public final class AirPlayReceiver {
    public struct Configuration: Sendable {
        /// Shown in the sender's list of screens.
        public var name: String
        /// Six bytes that identify this receiver to senders; keep them stable between launches.
        public var deviceID: [UInt8]
        /// Where the receiver keeps its key pair between launches. Nil derives the key from the device ID.
        public var keyFile: URL?
        public var allowHEVC: Bool
        /// The largest picture a sender should send.
        public var width: Int
        public var height: Int
        public var maxFPS: Int
        /// Highest syslog level of protocol messages passed to `Events.log` (6 info, 7 debug).
        public var logLevel: Int
        package var mirrorSilenceTimeout: Int32 = 0

        public init(
            name: String, deviceID: [UInt8], keyFile: URL? = nil, allowHEVC: Bool = true,
            width: Int = 1920, height: Int = 1080, maxFPS: Int = 60, logLevel: Int = 6
        ) {
            self.name = name
            self.deviceID = deviceID
            self.keyFile = keyFile
            self.allowHEVC = allowHEVC
            self.width = width
            self.height = height
            self.maxFPS = maxFPS
            self.logLevel = logLevel
        }
    }

    /// Every closure runs on one of the receiver's own threads.
    public struct Events {
        public var clientRequested: ((_ name: String, _ model: String) -> Void)?
        /// The mirroring stream started (true) or ended (false).
        public var mirroringChanged: ((Bool) -> Void)?
        public var videoFormat: ((_ codec: VideoCodec, _ width: Int, _ height: Int) -> Void)?
        /// One Annex B packet. `captureTime` is on the clock of `AirPlayReceiver.now()`, or 0 while unsynchronised.
        public var videoPacket: ((_ data: Data, _ codec: VideoCodec, _ captureTime: UInt64) -> Void)?
        /// The stream was interrupted; decoding restarts from the next key frame.
        public var videoReset: (() -> Void)?
        public var log: ((_ level: Int, _ message: String) -> Void)?

        public init() {}
    }

    public enum StartError: Error, Equatable {
        /// `step` names the stage that failed: 1 arguments, 2 Bonjour, 3-4 protocol set-up, 5 listening, 6 advertising.
        case failed(step: Int)
    }

    /// Keeps the event closures alive for the C callbacks, which only carry a pointer.
    private final class EventBox {
        let events: Events

        init(_ events: Events) {
            self.events = events
        }

        static func from(_ context: UnsafeMutableRawPointer?) -> Events? {
            context.map { Unmanaged<EventBox>.fromOpaque($0).takeUnretainedValue().events }
        }
    }

    /// TCP port the receiver listens on.
    public let port: UInt16

    private let box: EventBox
    private let lock = NSLock()
    private var handle: OpaquePointer?

    /// Starts listening and advertising.
    public init(configuration: Configuration, events: Events) throws {
        guard configuration.deviceID.count == 6 else { throw StartError.failed(step: 1) }
        let box = EventBox(events)

        var callbacks = vpv_receiver_callbacks_t()
        callbacks.context = Unmanaged.passUnretained(box).toOpaque()
        callbacks.client_request = { context, name, model in
            EventBox.from(context)?.clientRequested?(
                name.map { String(cString: $0) } ?? "", model.map { String(cString: $0) } ?? "")
        }
        callbacks.mirror_running = { context, running in
            EventBox.from(context)?.mirroringChanged?(running)
        }
        callbacks.video_format = { context, codec, width, height in
            EventBox.from(context)?.videoFormat?(codec == VPV_CODEC_H265 ? .hevc : .h264, Int(width), Int(height))
        }
        callbacks.video_data = { context, codec, data, length, captureTime in
            guard let data, length > 0, let handler = EventBox.from(context)?.videoPacket else { return }
            // The bytes belong to the protocol library and are freed when this returns.
            handler(Data(bytes: data, count: Int(length)), codec == VPV_CODEC_H265 ? .hevc : .h264, captureTime)
        }
        callbacks.video_reset = { context in
            EventBox.from(context)?.videoReset?()
        }
        callbacks.log = { context, level, message in
            guard let message, let handler = EventBox.from(context)?.log else { return }
            handler(Int(level), String(cString: message))
        }

        let id = configuration.deviceID
        var error: Int32 = 0
        let started: OpaquePointer? = configuration.name.withCString { name in
            (configuration.keyFile?.path ?? "").withCString { keyFile in
                var config = vpv_receiver_config_t()
                config.name = name
                config.device_id = (id[0], id[1], id[2], id[3], id[4], id[5])
                config.key_file = keyFile
                config.allow_h265 = configuration.allowHEVC
                config.width = Int32(clamping: configuration.width)
                config.height = Int32(clamping: configuration.height)
                config.refresh_rate = Int32(clamping: configuration.maxFPS)
                config.max_fps = Int32(clamping: configuration.maxFPS)
                config.log_level = Int32(clamping: configuration.logLevel)
                config.mirror_silence_timeout = configuration.mirrorSilenceTimeout
                return vpv_receiver_start(&config, &callbacks, &error)
            }
        }
        guard let started else { throw StartError.failed(step: Int(error)) }
        self.box = box
        self.handle = started
        self.port = vpv_receiver_port(started)
    }

    deinit {
        stop()
    }

    /// Stops advertising and ends any session. No event runs after this returns. Safe to call twice.
    /// Do not call it from inside an event.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        let running = handle
        handle = nil
        if let running {
            vpv_receiver_stop(running)
        }
    }

    /// Nanoseconds on the clock used for capture times.
    public static func now() -> UInt64 {
        vpv_receiver_now_ns()
    }

    /// Six random bytes in the form of a locally administered MAC address.
    public static func randomDeviceID() -> [UInt8] {
        var bytes = (0..<6).map { _ in UInt8.random(in: .min ... .max) }
        // Bit 1 set: locally administered. Bit 0 clear: one device, not a group.
        bytes[0] = (bytes[0] & 0xfc) | 0x02
        return bytes
    }
}
