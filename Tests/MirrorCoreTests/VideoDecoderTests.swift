import CoreVideo
import Foundation
import Testing
import MirrorCore

/// Real encoded video through the decoder.
@Suite struct VideoDecoderTests {
    private func size(of picture: CVPixelBuffer) -> CGSize {
        CGSize(width: CVPixelBufferGetWidth(picture), height: CVPixelBufferGetHeight(picture))
    }

    @Test(arguments: [VideoCodec.h264, VideoCodec.hevc])
    func everyFrameOfAStreamIsDecodedAtItsSize(codec: VideoCodec) throws {
        let packets = try SyntheticStream.packets(codec: codec, width: 640, height: 360, frames: 6)
        let decoder = VideoDecoder()
        let pictures = try packets.compactMap { try decoder.decode($0, codec: codec) }
        #expect(pictures.map(size) == Array(repeating: CGSize(width: 640, height: 360), count: 6))
    }

    @Test(arguments: [VideoCodec.h264, VideoCodec.hevc])
    func decodedPicturesShowWhatWasEncoded(codec: VideoCodec) throws {
        // The synthetic frames get brighter by 20 levels each; a blank or stale picture would not.
        let packets = try SyntheticStream.packets(codec: codec, width: 640, height: 360, frames: 4)
        let decoder = VideoDecoder()
        let pictures = try packets.compactMap { try decoder.decode($0, codec: codec) }
        try #require(pictures.count == 4)
        let brightness = try pictures.map { try SyntheticStream.meanLuma(of: $0) }
        for index in 1..<4 {
            let step = brightness[index] - brightness[index - 1]
            #expect(step > 10 && step < 30, "brightness \(brightness)")
        }
    }

    @Test func decodedPicturesAreBackedByASurfaceALayerCanShow() throws {
        let packets = try SyntheticStream.packets(codec: .h264, width: 640, height: 360, frames: 1)
        let picture = try #require(try VideoDecoder().decode(packets[0], codec: .h264))
        #expect(CVPixelBufferGetIOSurface(picture) != nil)
    }

    @Test func framesThatArriveBeforeAKeyFrameProduceNothing() throws {
        let packets = try SyntheticStream.packets(codec: .h264, width: 640, height: 360, frames: 3)
        let decoder = VideoDecoder()
        #expect(try decoder.decode(packets[1], codec: .h264) == nil)
        #expect(try decoder.decode(packets[2], codec: .h264) == nil)
        #expect(try decoder.decode(packets[0], codec: .h264) != nil)
        #expect(try decoder.decode(packets[1], codec: .h264) != nil)
    }

    @Test func afterResetTheDecoderWaitsForTheNextStream() throws {
        let packets = try SyntheticStream.packets(codec: .h264, width: 640, height: 360, frames: 3)
        let decoder = VideoDecoder()
        _ = try decoder.decode(packets[0], codec: .h264)
        decoder.reset()
        #expect(try decoder.decode(packets[1], codec: .h264) == nil)
        #expect(try decoder.decode(packets[0], codec: .h264) != nil)
        #expect(try decoder.decode(packets[1], codec: .h264) != nil)
    }

    @Test(arguments: [VideoCodec.h264, VideoCodec.hevc])
    func jumpingToAnIndependentFramePreservesTheDecoderSession(codec: VideoCodec) throws {
        let packets = try SyntheticStream.packets(codec: codec, width: 640, height: 360, frames: 8, keyFrameInterval: 4)
        let parsed = packets.compactMap { VideoPacketParser.parse($0, codec: codec) }
        let sync = parsed.indices.filter { parsed[$0].isKeyFrame }
        try #require(sync.count >= 2)
        let decoder = VideoDecoder()
        _ = try decoder.decode(parsed[sync[0]], codec: codec)
        let before = try #require(decoder.sessionIdentity)
        decoder.resumeAtKeyFrame()
        #expect(try decoder.decode(parsed[sync[1] - 1], codec: codec) == nil)
        #expect(try decoder.decode(parsed[sync[1]], codec: codec) != nil)
        #expect(decoder.sessionIdentity == before)
    }

    @Test func aStreamThatChangesSizeIsDecodedAtTheNewSize() throws {
        // A phone turning from landscape to portrait sends new parameter sets and a key frame.
        let landscape = try SyntheticStream.packets(codec: .h264, width: 640, height: 360, frames: 2)
        let portrait = try SyntheticStream.packets(codec: .h264, width: 360, height: 640, frames: 2)
        let decoder = VideoDecoder()
        let pictures = try (landscape + portrait).compactMap { try decoder.decode($0, codec: .h264) }
        #expect(pictures.map(size) == [
            CGSize(width: 640, height: 360), CGSize(width: 640, height: 360),
            CGSize(width: 360, height: 640), CGSize(width: 360, height: 640),
        ])
    }

    @Test func aStreamThatChangesCodecIsDecoded() throws {
        let first = try SyntheticStream.packets(codec: .h264, width: 640, height: 360, frames: 2)
        let second = try SyntheticStream.packets(codec: .hevc, width: 640, height: 360, frames: 2)
        let decoder = VideoDecoder()
        var pictures = try first.compactMap { try decoder.decode($0, codec: .h264) }
        pictures += try second.compactMap { try decoder.decode($0, codec: .hevc) }
        #expect(pictures.count == 4)
    }

    @Test func damagedPacketProducesNothingAndDoesNotThrow() throws {
        let decoder = VideoDecoder()
        #expect(try decoder.decode(Data([1, 0, 0, 1, 0x65, 0x88]), codec: .h264) == nil)
        #expect(try decoder.decode(Data(), codec: .h264) == nil)
    }

    @Test func parameterSetsThatDescribeNoFormatAreReportedAndTheNextStreamStillDecodes() throws {
        let decoder = VideoDecoder()
        // Well-formed NAL units whose contents are not a real sequence parameter set.
        #expect(throws: VideoDecoderError.self) {
            _ = try decoder.decode(annexB([[0x67, 0xff], [0x68, 0xff], [0x65, 0x88, 0x80]]), codec: .h264)
        }
        let packets = try SyntheticStream.packets(codec: .h264, width: 640, height: 360, frames: 2)
        #expect(try decoder.decode(packets[0], codec: .h264) != nil)
        #expect(try decoder.decode(packets[1], codec: .h264) != nil)
    }
}
