import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum VideoDecoderError: Error, Equatable {
    /// The stream's parameter sets do not describe a format the system can decode.
    case format(OSStatus)
    case sample(OSStatus)
    /// No decoder could be set up for the format.
    case session(OSStatus)
    /// The decoder rejected a frame.
    case decode(OSStatus)
}

/// Decodes the receiver's Annex B packets into pictures with the system's hardware decoder.
/// Not thread-safe: use it from one queue.
public final class VideoDecoder {
    private var gate = VideoStreamGate()
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var codec: VideoCodec?

    public init() {}

    deinit {
        invalidateSession()
    }

    /// A new stream follows: forget the format and wait for parameter sets and a key frame.
    public func reset() {
        gate.reset()
        format = nil
        codec = nil
        invalidateSession()
    }

    /// A newer independent picture is available in the same stream. Keep the existing format and session.
    package func resumeAtKeyFrame() { gate.requireKeyFrame() }

    package var sessionIdentity: ObjectIdentifier? { session.map(ObjectIdentifier.init) }

    /// Decodes one packet and returns its picture, backed by an IOSurface so a layer can show it without a copy.
    /// Returns nil when the packet holds nothing to show yet: parameter sets only, damaged data,
    /// or a frame that cannot be decoded before the next key frame.
    /// Throws when the decoder rejects the packet; decoding then resumes at the next key frame.
    public func decode(_ annexB: Data, codec: VideoCodec) throws -> CVPixelBuffer? {
        guard let packet = VideoPacketParser.parse(annexB, codec: codec) else { return nil }
        return try decode(packet, codec: codec)
    }

    package func decode(_ packet: VideoPacket, codec: VideoCodec) throws -> CVPixelBuffer? {
        if self.codec != codec {
            reset()
            self.codec = codec
        }
        guard case .decode(let newSets) = gate.decide(packet) else { return nil }
        if let newSets {
            do {
                let newFormat = try Self.makeFormat(newSets)
                if let session, !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newFormat) {
                    invalidateSession()
                }
                format = newFormat
            } catch {
                // Nothing can be decoded until parameter sets arrive again.
                reset()
                throw error
            }
        }
        guard let format else { return nil }
        do {
            let session = try self.session ?? makeSession(for: format)
            let sample = try Self.makeSample(packet.sample, format: format)
            var picture: CVPixelBuffer?
            var frameStatus = noErr
            // Without the asynchronous flag the handler runs before this call returns.
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
                status, _, image, _, _ in
                frameStatus = status
                picture = image
            }
            guard status == noErr else { throw VideoDecoderError.decode(status) }
            guard frameStatus == noErr else { throw VideoDecoderError.decode(frameStatus) }
            return picture
        } catch {
            // A fresh decoder can only start at a key frame.
            invalidateSession()
            gate.requireKeyFrame()
            throw error
        }
    }

    private func makeSession(for format: CMVideoFormatDescription) throws -> VTDecompressionSession {
        // IOSurface-backed output in the decoder's own pixel format: no conversion, and a layer can show it as is.
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &created)
        guard status == noErr, let created else { throw VideoDecoderError.session(status) }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        return created
    }

    private func invalidateSession() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }

    private static func makeFormat(_ sets: ParameterSets) throws -> CMVideoFormatDescription {
        let ordered = sets.ordered
        // One contiguous copy, so every parameter set has a pointer that stays valid for the call.
        var joined = [UInt8]()
        var offsets = [Int]()
        for set in ordered {
            offsets.append(joined.count)
            joined.append(contentsOf: set)
        }
        let sizes = ordered.map(\.count)
        var format: CMFormatDescription?
        let status = joined.withUnsafeBufferPointer { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kCMFormatDescriptionError_InvalidParameter }
            let pointers = offsets.map { base + $0 }
            switch sets.codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else { throw VideoDecoderError.format(status) }
        return format
    }

    /// Wraps length-prefixed NAL units as one sample.
    private static func makeSample(_ data: Data, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { throw VideoDecoderError.sample(status) }
        status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == kCMBlockBufferNoErr else { throw VideoDecoderError.sample(status) }
        var sample: CMSampleBuffer?
        var size = data.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw VideoDecoderError.sample(status) }
        return sample
    }
}
