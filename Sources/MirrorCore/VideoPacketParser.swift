import Foundation

public enum VideoCodec: Equatable, Sendable {
    case h264
    case hevc
}

/// The parameter sets a decoder needs before it can decode the first frame.
public struct ParameterSets: Equatable, Sendable {
    public var codec: VideoCodec
    /// Video parameter sets; HEVC only.
    public var vps: [Data]
    public var sps: [Data]
    public var pps: [Data]

    public init(codec: VideoCodec, vps: [Data] = [], sps: [Data], pps: [Data]) {
        self.codec = codec
        self.vps = vps
        self.sps = sps
        self.pps = pps
    }

    /// In the order a decoder configuration lists them: VPS, SPS, PPS.
    public var ordered: [Data] { vps + sps + pps }
}

/// One packet from the receiver, split into what configures the decoder and what it decodes.
public struct VideoPacket: Equatable, Sendable {
    /// A complete set found in this packet, if any.
    public var parameterSets: ParameterSets?
    /// Every other NAL unit, each behind its 4-byte big-endian length. Empty when the packet had none.
    public var sample: Data
    public var isKeyFrame: Bool

    public init(parameterSets: ParameterSets?, sample: Data, isKeyFrame: Bool) {
        self.parameterSets = parameterSets
        self.sample = sample
        self.isKeyFrame = isKeyFrame
    }
}

public enum VideoPacketParser {
    private enum Kind {
        case vps, sps, pps, keySlice, other
    }

    /// Parses an Annex B packet whose NAL units are separated by `00 00 00 01`. Returns nil for damaged data.
    public static func parse(_ annexB: Data, codec: VideoCodec) -> VideoPacket? {
        annexB.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> VideoPacket? in
            let count = raw.count
            // A packet starts with a start code. The protocol library overwrites its first byte with 1
            // when decryption produced garbage, which fails this check.
            guard count > 4, raw[0] == 0, raw[1] == 0, raw[2] == 0, raw[3] == 1 else { return nil }
            var vps = [Data]()
            var sps = [Data]()
            var pps = [Data]()
            var sample = Data()
            sample.reserveCapacity(count)
            var isKeyFrame = false

            var start = 4
            while start < count {
                let end = nextStartCode(in: raw, from: start) ?? count
                // An empty unit, a start code with nothing after it, or the forbidden bit set: not video.
                guard end > start, end == count || end + 4 < count, raw[start] & 0x80 == 0 else { return nil }
                guard codec != .hevc || end - start >= 2 else { return nil }
                let unit = UnsafeRawBufferPointer(rebasing: raw[start..<end])
                switch kind(of: raw[start], codec: codec) {
                case .vps:
                    vps.append(Data(unit))
                case .sps:
                    sps.append(Data(unit))
                case .pps:
                    pps.append(Data(unit))
                case .keySlice:
                    isKeyFrame = true
                    append(unit, to: &sample)
                case .other:
                    append(unit, to: &sample)
                }
                start = end + 4
            }

            let complete = !sps.isEmpty && !pps.isEmpty && (codec == .h264 || !vps.isEmpty)
            return VideoPacket(
                parameterSets: complete ? ParameterSets(codec: codec, vps: vps, sps: sps, pps: pps) : nil,
                sample: sample,
                isKeyFrame: isKeyFrame)
        }
    }

    /// Index of the next `00 00 00 01` at or after `from`.
    private static func nextStartCode(in raw: UnsafeRawBufferPointer, from: Int) -> Int? {
        let count = raw.count
        var index = from
        while index + 3 < count {
            // Any start code overlapping these four bytes has 0 or 1 at this position, so other values skip ahead.
            if raw[index + 3] > 1 {
                index += 4
            } else if raw[index] == 0, raw[index + 1] == 0, raw[index + 2] == 0, raw[index + 3] == 1 {
                return index
            } else {
                index += 1
            }
        }
        return nil
    }

    private static func kind(of firstByte: UInt8, codec: VideoCodec) -> Kind {
        switch codec {
        case .h264:
            // nal_unit_type is the low five bits.
            switch firstByte & 0x1f {
            case 7: return .sps
            case 8: return .pps
            case 5: return .keySlice
            default: return .other
            }
        case .hevc:
            // nal_unit_type is bits 1-6; types 16-23 are the random-access pictures.
            switch (firstByte >> 1) & 0x3f {
            case 32: return .vps
            case 33: return .sps
            case 34: return .pps
            case 16...23: return .keySlice
            default: return .other
            }
        }
    }

    private static func append(_ unit: UnsafeRawBufferPointer, to sample: inout Data) {
        let length = UInt32(unit.count)
        sample.append(contentsOf: [
            UInt8(length >> 24), UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
        ])
        sample.append(contentsOf: unit)
    }
}
