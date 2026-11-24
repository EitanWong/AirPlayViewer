/// Compressed video waiting for decode. Mutate under the caller's lock.
package struct VideoBacklog {
    package struct Frame {
        package var packet: VideoPacket
        package let codec: VideoCodec
        package let captureTime: UInt64
        package let bytes: Int
        package var restartDecoder = false
        fileprivate var enqueuedAt: Double = 0

        package init(packet: VideoPacket, codec: VideoCodec, captureTime: UInt64, bytes: Int) {
            self.packet = packet
            self.codec = codec
            self.captureTime = captureTime
            self.bytes = bytes
        }
    }

    private let frameLimit: Int
    private let byteLimit: Int
    private let delayLimit: Double
    private var pending: [Frame] = []
    private var pendingBytes = 0
    private var codec: VideoCodec?
    private var parameterSets: ParameterSets?
    private var needsKeyFrame = true

    package static func forLiveMirroring() -> Self {
        // Keep the reference chain across short TCP bursts. If a fresh key frame arrives,
        // the delay limit still lets decode jump ahead instead of presenting a stale queue.
        Self(frameLimit: 60, byteLimit: 24 * 1024 * 1024, delayLimit: 0.09)
    }

    package init(frameLimit: Int, byteLimit: Int, delayLimit: Double = .infinity) {
        precondition(frameLimit > 0 && byteLimit > 0)
        self.frameLimit = frameLimit
        self.byteLimit = byteLimit
        self.delayLimit = delayLimit
    }

    package var isEmpty: Bool { pending.isEmpty }

    package func shouldWaitForSpace(for frame: Frame) -> Bool {
        guard frame.codec == codec, !frame.packet.sample.isEmpty, !frame.packet.isKeyFrame,
              frame.bytes <= byteLimit else { return false }
        if let sets = frame.packet.parameterSets, sets != parameterSets { return false }
        return wouldOverrun(with: frame)
    }

    package mutating func clear() {
        _ = discardPending()
        codec = nil
        parameterSets = nil
    }

    /// Returns the number of pictures discarded. After a gap, never decode an arbitrary delta frame.
    package mutating func append(_ frame: Frame, at time: Double = 0) -> Int {
        var dropped = 0
        if codec != frame.codec {
            dropped += discardPending()
            codec = frame.codec
            parameterSets = nil
        }
        // Bound the memory retained by the cached configuration too.
        if frame.bytes > byteLimit {
            if frame.packet.parameterSets != nil { parameterSets = nil }
            return dropped + discardPending() + 1
        }
        if let sets = frame.packet.parameterSets, sets != parameterSets {
            if parameterSets != nil { dropped += discardPending() }
            parameterSets = sets
            needsKeyFrame = true
        }
        guard !frame.packet.sample.isEmpty else { return dropped }

        var next = frame
        next.enqueuedAt = time
        let overrun = wouldOverrun(with: frame)
        let late = pending.first.map { time - $0.enqueuedAt >= delayLimit } ?? false
        if frame.packet.isKeyFrame && (late || overrun) {
            dropped += discardPending()
        } else if overrun {
            // Preserve a queued sync point if it and its dependent suffix still fit.
            if let parameterSets, let key = pending.lastIndex(where: { $0.packet.isKeyFrame }), key > 0 {
                let keptBytes = pending[key...].reduce(0) { $0 + $1.bytes }
                if frame.bytes <= byteLimit - keptBytes {
                    pending.removeFirst(key)
                    pendingBytes = keptBytes
                    pending[0].packet.parameterSets = parameterSets
                    pending[0].restartDecoder = true
                    dropped += key
                } else {
                    dropped += discardPending()
                }
            } else {
                dropped += discardPending()
            }
        }
        if needsKeyFrame {
            guard frame.packet.isKeyFrame, let parameterSets else { return dropped + 1 }
            next.packet.parameterSets = parameterSets
            next.restartDecoder = true
            needsKeyFrame = false
        }
        pending.append(next)
        pendingBytes += next.bytes
        return dropped
    }

    package mutating func popFirst() -> Frame? {
        guard !pending.isEmpty else { return nil }
        let frame = pending.removeFirst()
        pendingBytes -= frame.bytes
        return frame
    }

    private mutating func discardPending() -> Int {
        let dropped = pending.count
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0
        needsKeyFrame = true
        return dropped
    }

    private func wouldOverrun(with frame: Frame) -> Bool {
        pending.count >= frameLimit || frame.bytes > byteLimit - pendingBytes
    }
}
