import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import MirrorCore

/// Test support: real encoded video in the shape the AirPlay receiver delivers it.
enum SyntheticStream {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Encodes `frames` pictures and returns one Annex B packet per frame.
    /// Parameter sets sit in front of each key frame; by default only the first frame is a key frame.
    static func packets(codec: VideoCodec, width: Int, height: Int, frames: Int, keyFrameInterval: Int? = nil) throws -> [Data] {
        var session: VTCompressionSession?
        let type = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: type,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw Failure(description: "encoder create \(status)") }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: keyFrameInterval ?? frames * 4))

        let lock = NSLock()
        var encoded = [CMSampleBuffer]()
        let levelStep = min(20, 200 / max(1, frames - 1))
        for index in 0..<frames {
            let picture = try pixelBuffer(width: width, height: height, level: UInt8(40 + index * levelStep))
            status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: picture,
                presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
                duration: CMTime(value: 1, timescale: 30), frameProperties: nil, infoFlagsOut: nil
            ) { frameStatus, _, sampleBuffer in
                guard frameStatus == noErr, let sampleBuffer else { return }
                lock.lock()
                encoded.append(sampleBuffer)
                lock.unlock()
            }
            guard status == noErr else { throw Failure(description: "encode \(status)") }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        lock.lock()
        let buffers = encoded.sorted { $0.presentationTimeStamp < $1.presentationTimeStamp }
        lock.unlock()
        guard buffers.count == frames else { throw Failure(description: "encoded \(buffers.count) of \(frames) frames") }
        return try buffers.map { try annexBPacket(from: $0, codec: codec) }
    }

    /// Average brightness (0-255) of a decoded 8-bit picture's luma plane.
    static func meanLuma(of picture: CVPixelBuffer) throws -> Double {
        CVPixelBufferLockBaseAddress(picture, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
        guard CVPixelBufferGetPlaneCount(picture) >= 1, let base = CVPixelBufferGetBaseAddressOfPlane(picture, 0) else {
            throw Failure(description: "picture has no luma plane")
        }
        let width = CVPixelBufferGetWidthOfPlane(picture, 0)
        let height = CVPixelBufferGetHeightOfPlane(picture, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(picture, 0)
        var total = 0
        for row in 0..<height {
            let line = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self)
            for column in 0..<width { total += Int(line[column]) }
        }
        return Double(total) / Double(width * height)
    }

    private static func pixelBuffer(width: Int, height: Int, level: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw Failure(description: "pixel buffer \(status)") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure(description: "pixel buffer base") }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<height {
            // A gentle ramp on top of the frame's level, so frames differ and compress to real slices.
            // The ramp adds at most 88, which keeps every value below 256 for levels up to 160.
            let line = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self)
            for column in 0..<width {
                let value = UInt8(min(255, Int(level) + column * 60 / width + row * 30 / height))
                line[column * 4] = value
                line[column * 4 + 1] = value
                line[column * 4 + 2] = value
                line[column * 4 + 3] = 255
            }
        }
        return buffer
    }

    private static func annexBPacket(from sampleBuffer: CMSampleBuffer, codec: VideoCodec) throws -> Data {
        guard let format = sampleBuffer.formatDescription, let block = sampleBuffer.dataBuffer else {
            throw Failure(description: "encoded sample without data")
        }
        let startCode = Data([0, 0, 0, 1])
        var packet = Data()
        var lengthSize: Int32 = 0
        var count = 0
        let sets = try parameterSets(of: format, codec: codec, count: &count, lengthSize: &lengthSize)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        if !notSync {
            for set in sets { packet += startCode + set }
        }
        var bytes = Data(count: CMBlockBufferGetDataLength(block))
        let copied = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { throw Failure(description: "block copy \(copied)") }
        var offset = 0
        let prefix = Int(lengthSize)
        while offset + prefix <= bytes.count {
            var length = 0
            for index in 0..<prefix { length = length << 8 | Int(bytes[offset + index]) }
            offset += prefix
            guard length > 0, offset + length <= bytes.count else { throw Failure(description: "bad NAL length") }
            packet += startCode + bytes[offset..<(offset + length)]
            offset += length
        }
        return packet
    }

    private static func parameterSets(
        of format: CMFormatDescription, codec: VideoCodec, count: inout Int, lengthSize: inout Int32
    ) throws -> [Data] {
        func set(at index: Int) -> (OSStatus, Data) {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = codec == .hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize)
            return (status, pointer.map { Data(bytes: $0, count: size) } ?? Data())
        }
        let (status, first) = set(at: 0)
        guard status == noErr, count > 0 else { throw Failure(description: "parameter sets \(status)") }
        return [first] + (1..<count).map { set(at: $0).1 }
    }
}
