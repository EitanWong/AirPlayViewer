import CoreMedia
import CoreVideo
import Foundation
import MirrorCore
import Testing
import VideoToolbox

@Suite(.serialized)
struct IndependentVideoTests {
    @Test(arguments: [VideoCodec.h264, .hevc])
    func decodesEveryFrameAcrossTwoKeyFrames(codec: VideoCodec) throws {
        let stream = try encode(codec: codec)
        let decoder = VideoDecoder()
        var decoded = 0
        for (index, frame) in stream.enumerated() {
            let packet = frame.annexB
            let parsed = try #require(VideoPacketParser.parse(packet, codec: codec))
            #expect(parsed.isKeyFrame == (index == 0 || index == 4), "Frame \(index)")
            #expect((parsed.parameterSets != nil) == frame.isSync, "Frame \(index)")
            if let picture = try decoder.decode(packet, codec: codec) {
                expectSurface(picture, width: 96, height: 64)
                decoded += 1
            } else {
                Issue.record("Missing decoded picture for frame \(index)")
            }
        }
        #expect(decoded == 8)
    }

    @Test(arguments: [VideoCodec.h264, .hevc])
    func randomBytesAndTruncatedSamplesDoNotCrash(codec: VideoCodec) throws {
        let stream = try encode(codec: codec)
        let decoder = VideoDecoder()
        var random = IndependentRandom()
        for index in 0..<512 {
            let size = index % 193
            var bytes = Data((0..<size).map { _ in random.byte() })
            if index % 3 != 0 {
                // Exercise the NAL scanner as well as rejection at the first start code.
                bytes = annexBStart + bytes
                if index % 3 == 2 {
                    let middle = 4 + size / 2
                    bytes.insert(contentsOf: annexBStart, at: middle)
                }
            }
            _ = VideoPacketParser.parse(bytes, codec: codec)
            try tolerateRejectedInput(bytes, decoder: decoder, codec: codec)
        }

        // Use genuine compressed bytes so cuts also exercise the configured decoder.
        let sync = stream[0].annexB
        let delta = stream[1].picture
        for packet in [sync, delta] {
            let cuts = Set(0..<min(packet.count, 24)).union([packet.count / 2, packet.count - 1])
            for cut in cuts.sorted() {
                decoder.reset()
                _ = try #require(try decoder.decode(sync, codec: codec))
                let truncated = Data(packet.prefix(cut))
                _ = VideoPacketParser.parse(truncated, codec: codec)
                try tolerateRejectedInput(truncated, decoder: decoder, codec: codec)
                _ = try #require(try decoder.decode(stream[4].annexB, codec: codec))
            }
        }
    }

    @Test
    func rejectsTruncatedHEVCNALHeader() {
        // An HEVC NAL header takes two bytes, even when the packet starts correctly.
        let truncated = annexBStart + Data([0x26])
        let packet = VideoPacketParser.parse(truncated, codec: .hevc)
        #expect(packet == nil)
    }

    @Test(arguments: [VideoCodec.h264, .hevc])
    func resetAndResolutionChangeWaitForSync(codec: VideoCodec) throws {
        let initial = try encode(codec: codec)
        let resized = try encode(codec: codec, width: 128)
        let decoder = VideoDecoder()
        expectSurface(try #require(try decoder.decode(initial[0].annexB, codec: codec)), width: 96, height: 64)
        #expect(try decoder.decode(resized[0].parameters, codec: codec) == nil)
        #expect(try decoder.decode(resized[1].picture, codec: codec) == nil)
        expectSurface(try #require(try decoder.decode(resized[4].picture, codec: codec)), width: 128, height: 64)
        expectSurface(try #require(try decoder.decode(resized[5].picture, codec: codec)), width: 128, height: 64)

        decoder.reset()
        #expect(try decoder.decode(resized[4].picture, codec: codec) == nil)
        expectSurface(try #require(try decoder.decode(initial[0].annexB, codec: codec)), width: 96, height: 64)
    }

    @Test
    func newCodecWithoutConfigurationWaitsForItsOwnKeyFrame() throws {
        let h264 = try encode(codec: .h264)
        let hevc = try encode(codec: .hevc)
        let decoder = VideoDecoder()
        _ = try #require(try decoder.decode(h264[0].annexB, codec: .h264))
        // Simulate the sender's first HEVC packet (with its parameter sets) being lost.
        // The next packet is valid HEVC, but cannot be decoded against the previous H.264 format.
        do {
            #expect(try decoder.decode(hevc[1].picture, codec: .hevc) == nil)
        } catch {
            Issue.record("Unconfigured HEVC reached the H.264 decoder: \(error)")
        }
        _ = try #require(try decoder.decode(hevc[4].annexB, codec: .hevc))
        _ = try #require(try decoder.decode(hevc[5].picture, codec: .hevc))
    }

    @Test
    func concurrentStopWaitsForAnEventAlreadyInFlight() throws {
        let callbackEntered = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let secondReturned = DispatchSemaphore(value: 0)
        var events = AirPlayReceiver.Events()
        events.log = { _, message in
            // The listener emits this during its normal shutdown, even with no sender.
            guard message == "Exiting httpd thread" else { return }
            callbackEntered.signal()
            _ = releaseCallback.wait(timeout: .now() + .seconds(5))
        }
        let receiver = try AirPlayReceiver(
            configuration: .init(name: "VPV stop test \(UUID().uuidString.prefix(8))",
                                 deviceID: AirPlayReceiver.randomDeviceID(), logLevel: 7),
            events: events)
        let workers = DispatchGroup()
        defer {
            releaseCallback.signal()
            workers.wait()
        }
        DispatchQueue.global().async(group: workers) { receiver.stop() }
        try #require(callbackEntered.wait(timeout: .now() + .seconds(3)) == .success)
        DispatchQueue.global().async(group: workers) {
            secondStarted.signal()
            receiver.stop()
            secondReturned.signal()
        }
        try #require(secondStarted.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(secondReturned.wait(timeout: .now() + .milliseconds(250)) == .timedOut)
    }
}

private let annexBStart = Data([0, 0, 0, 1])

private struct IndependentRandom {
    private var state: UInt64 = 0xe145_a567_48bc_129f

    mutating func byte() -> UInt8 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return UInt8(truncatingIfNeeded: state)
    }
}

private func tolerateRejectedInput(_ data: Data, decoder: VideoDecoder, codec: VideoCodec) throws {
    do {
        _ = try decoder.decode(data, codec: codec)
    } catch is VideoDecoderError {
        // Either a nil result or a documented decode error is a valid outcome for damaged input.
    }
}

private func expectSurface(_ picture: CVPixelBuffer, width: Int, height: Int) {
    #expect(CVPixelBufferGetWidth(picture) == width)
    #expect(CVPixelBufferGetHeight(picture) == height)
    #expect(CVPixelBufferGetIOSurface(picture) != nil)
}

private struct IndependentEncodedFrame {
    let parameters: Data
    let picture: Data
    let isSync: Bool
    var annexB: Data { parameters + picture }
}

private final class IndependentEncoderOutput: @unchecked Sendable {
    struct Entry {
        let status: OSStatus
        let flags: VTEncodeInfoFlags
        let sample: CMSampleBuffer?
    }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]

    func record(_ entry: Entry, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        entries[index] = entry
    }

    func entry(at index: Int) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[index]
    }
}

private func encode(codec: VideoCodec, width: Int = 96, height: Int = 64) throws -> [IndependentEncodedFrame] {
    var session: VTCompressionSession?
    let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let attributes = [kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    try #require(VTCompressionSessionCreate(
        allocator: nil, width: Int32(width), height: Int32(height), codecType: codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
        encoderSpecification: nil, imageBufferAttributes: attributes, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr)
    let encoder = try #require(session)
    defer { VTCompressionSessionInvalidate(encoder) }
    try #require(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue) == noErr)
    try #require(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse) == noErr)
    try #require(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 120 as CFNumber) == noErr)
    try #require(VTCompressionSessionPrepareToEncodeFrames(encoder) == noErr)
    let pool = try #require(VTCompressionSessionGetPixelBufferPool(encoder))
    let output = IndependentEncoderOutput()
    let indices = 0..<8
    for index in indices {
        var pixelBuffer: CVPixelBuffer?
        try #require(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess)
        let image = try #require(pixelBuffer)
        try fill(image, luma: UInt8(32 + 20 * index))
        let options = index == 4 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: image, presentationTimeStamp: CMTime(value: Int64(index), timescale: 30),
            duration: CMTime(value: 1, timescale: 30), frameProperties: options, infoFlagsOut: nil
        ) { status, flags, sample in
            output.record(.init(status: status, flags: flags, sample: sample), at: index)
        }
        try #require(status == noErr, "Frame \(index)")
    }
    try #require(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid) == noErr)
    return try indices.map { index in
        let entry = try #require(output.entry(at: index), "Encoder did not return frame \(index)")
        try #require(entry.status == noErr && !entry.flags.contains(.frameDropped), "Frame \(index)")
        let sample = try #require(entry.sample)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isSync = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        try #require(isSync == (index == 0 || index == 4), "Unexpected key-frame placement at frame \(index)")
        return try makeAnnexB(sample, codec: codec, isSync: isSync)
    }
}

private func fill(_ image: CVPixelBuffer, luma: UInt8) throws {
    try #require(CVPixelBufferLockBaseAddress(image, []) == kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(image, []) }
    try #require(CVPixelBufferGetPlaneCount(image) == 2)
    for plane in 0..<2 {
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(image, plane))
        memset(base, plane == 0 ? Int32(luma) : 128,
               CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane))
    }
}

private func makeAnnexB(_ sample: CMSampleBuffer, codec: VideoCodec, isSync: Bool) throws -> IndependentEncodedFrame {
    let format = try #require(CMSampleBufferGetFormatDescription(sample))
    func parameterSet(at index: Int, pointer: inout UnsafePointer<UInt8>?, size: inout Int,
                      count: inout Int, lengthSize: inout Int32) -> OSStatus {
        switch codec {
        case .h264:
            return CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize)
        case .hevc:
            return CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize)
        }
    }
    var pointer: UnsafePointer<UInt8>?
    var size = 0
    var count = 0
    var lengthSize: Int32 = 0
    try #require(parameterSet(at: 0, pointer: &pointer, size: &size, count: &count, lengthSize: &lengthSize) == noErr)
    try #require((1...4).contains(lengthSize))
    var parameters = Data()
    if isSync {
        for index in 0..<count {
            try #require(parameterSet(at: index, pointer: &pointer, size: &size, count: &count, lengthSize: &lengthSize) == noErr)
            parameters.append(annexBStart)
            parameters.append(Data(bytes: try #require(pointer), count: size))
        }
    }
    let block = try #require(CMSampleBufferGetDataBuffer(sample))
    var encoded = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
    try #require(!encoded.isEmpty)
    let status = encoded.withUnsafeMutableBytes { bytes in
        guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
        return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: base)
    }
    try #require(status == noErr)
    var picture = Data()
    var offset = 0
    while offset < encoded.count {
        let headerEnd = offset + Int(lengthSize)
        try #require(headerEnd <= encoded.count)
        let length = encoded[offset..<headerEnd].reduce(0) { ($0 << 8) | Int($1) }
        try #require(length > 0 && length <= encoded.count - headerEnd)
        picture.append(annexBStart)
        picture.append(contentsOf: encoded[headerEnd..<(headerEnd + length)])
        offset = headerEnd + length
    }
    return IndependentEncodedFrame(parameters: parameters, picture: picture, isSync: isSync)
}
