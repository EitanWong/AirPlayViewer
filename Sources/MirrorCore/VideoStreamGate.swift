import Foundation

/// Decides which packets may go to the decoder: nothing before parameter sets and a key frame.
public struct VideoStreamGate {
    public enum Decision: Equatable {
        case drop
        /// Decode the packet's sample. `newFormat` is set when the decoder must be reconfigured first.
        case decode(newFormat: ParameterSets?)
    }

    private var current: ParameterSets?
    /// Parameter sets the decoder has not been given yet.
    private var pending: ParameterSets?
    private var needsKeyFrame = true

    public init() {}

    /// A new stream follows: forget the format and wait for parameter sets and a key frame.
    public mutating func reset() {
        current = nil
        pending = nil
        needsKeyFrame = true
    }

    /// The decoder lost its state: keep the format but wait for the next key frame.
    public mutating func requireKeyFrame() {
        needsKeyFrame = true
    }

    public mutating func decide(_ packet: VideoPacket) -> Decision {
        // Senders repeat the same parameter sets often; only a change reconfigures the decoder.
        if let sets = packet.parameterSets, sets != current {
            current = sets
            pending = sets
            needsKeyFrame = true
        }
        guard current != nil, !packet.sample.isEmpty else { return .drop }
        if needsKeyFrame && !packet.isKeyFrame { return .drop }
        needsKeyFrame = false
        defer { pending = nil }
        return .decode(newFormat: pending)
    }
}
