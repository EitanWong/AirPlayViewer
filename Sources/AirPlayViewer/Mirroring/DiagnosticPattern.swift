import CoreMedia
import CoreVideo
import Foundation
import MirrorCore
import VideoToolbox

/// Diagnostic: an encoded moving test picture, delivered the way the receiver delivers video.
/// Started with the launch argument `-DiagnosticPattern YES`, it lets the decode and display path be
/// checked without a sender.
final class DiagnosticPattern {
    private let output: (Data, VideoCodec) -> Void
    private let queue = DispatchQueue(label: "com.eitan.AirPlayViewer.pattern")
    private var session: VTCompressionSession?
    private var timer: DispatchSourceTimer?
    private var frameIndex = 0
    private let width = 1280
    private let height = 720

    init(output: @escaping (Data, VideoCodec) -> Void) {
        self.output = output
    }

    func start() {
        queue.async { [self] in
            var created: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
            guard status == noErr, let created else { return }
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 60))
            session = created
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.encodeNextFrame() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            if let session { VTCompressionSessionInvalidate(session) }
            session = nil
        }
    }

    private func encodeNextFrame() {
        guard let session, let picture = makePicture(index: frameIndex) else { return }
        let time = CMTime(value: CMTimeValue(frameIndex), timescale: 30)
        frameIndex += 1
        let output = self.output
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: picture, presentationTimeStamp: time,
            duration: CMTime(value: 1, timescale: 30), frameProperties: nil, infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let packet = Self.annexBPacket(from: sampleBuffer) else { return }
            output(packet, .h264)
        }
    }

    /// Grey ramp with a white bar that crosses the picture every two seconds and a block that climbs the left edge.
    private func makePicture(index: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let barLeft = (index % 60) * width / 60
        let blockTop = height - 80 - (index % 90) * (height - 80) / 90
        for row in 0..<height {
            let line = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self)
            for column in 0..<width {
                var red = UInt8(40 + column * 120 / width)
                var green = UInt8(40 + row * 120 / height)
                var blue: UInt8 = 110
                if column >= barLeft && column < barLeft + 40 {
                    red = 255; green = 255; blue = 255
                } else if column < 80 && row >= blockTop && row < blockTop + 80 {
                    red = 255; green = 200; blue = 0
                }
                line[column * 4] = blue
                line[column * 4 + 1] = green
                line[column * 4 + 2] = red
                line[column * 4 + 3] = 255
            }
        }
        return buffer
    }

    /// Rewrites an encoder sample as the receiver would deliver it: start codes, parameter sets ahead of key frames.
    private static func annexBPacket(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let format = sampleBuffer.formatDescription, let block = sampleBuffer.dataBuffer else { return nil }
        let startCode = Data([0, 0, 0, 1])
        var packet = Data()
        var count = 0
        var lengthSize: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize) == noErr else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyFrame = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if isKeyFrame {
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
                packet += startCode + Data(bytes: pointer, count: size)
            }
        }
        var bytes = Data(count: CMBlockBufferGetDataLength(block))
        let copied = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        let prefix = Int(lengthSize)
        var offset = 0
        while offset + prefix <= bytes.count {
            var length = 0
            for index in 0..<prefix { length = length << 8 | Int(bytes[offset + index]) }
            offset += prefix
            guard length > 0, offset + length <= bytes.count else { return nil }
            packet += startCode + bytes[offset..<(offset + length)]
            offset += length
        }
        return packet
    }
}
