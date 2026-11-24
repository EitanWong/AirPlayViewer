import Foundation
import Testing
@testable import MirrorCore

@Suite struct VideoBacklogTests {
    @Test func fullQueueMakesDependentPacketsWaitForTheDecoder() throws {
        var backlog = VideoBacklog(frameLimit: 2, byteLimit: 64)
        let key = try frame(annexB([h264SPS, h264PPS, h264IDR]), at: 1)
        let delta = try frame(annexB([h264Delta]), at: 2)
        _ = backlog.append(key)
        _ = backlog.append(delta)
        #expect(backlog.shouldWaitForSpace(for: delta))
        #expect(!backlog.shouldWaitForSpace(for: key))
        _ = backlog.popFirst()
        #expect(!backlog.shouldWaitForSpace(for: delta))
        #expect(backlog.append(delta) == 0)
    }

    @Test(arguments: [VideoCodec.h264, .hevc])
    func liveQueuePreservesTheReferenceChainAcrossAnArrivalBurst(codec: VideoCodec) throws {
        var backlog = VideoBacklog.forLiveMirroring()
        let decoder = VideoDecoder()
        let encoded = try SyntheticStream.packets(codec: codec, width: 160, height: 96, frames: 25)
        let frames = try encoded.enumerated().map { index, data in
            let packet = try #require(VideoPacketParser.parse(data, codec: codec))
            return VideoBacklog.Frame(packet: packet, codec: codec, captureTime: UInt64(index), bytes: data.count)
        }
        _ = backlog.append(frames[0], at: 1)
        let queuedFirst = backlog.popFirst()
        let first = try #require(queuedFirst)
        #expect(try decoder.decode(first.packet, codec: codec) != nil)
        // The last independent frame was already decoded; every frame in the burst depends on it.
        #expect(frames.dropFirst().allSatisfy { !$0.packet.isKeyFrame })
        var discarded = 0
        for frame in frames.dropFirst() {
            discarded += backlog.append(frame, at: 2)
        }
        #expect(discarded == 0)
        var decodeOrder: [UInt64] = []
        while let queued = backlog.popFirst() {
            if try decoder.decode(queued.packet, codec: codec) != nil { decodeOrder.append(queued.captureTime) }
        }
        #expect(decodeOrder == frames.dropFirst().map(\.captureTime))
    }

    @Test func overrunDropsOldFramesAndRestartsFromKeyFrameWithCachedFormat() throws {
        var backlog = VideoBacklog(frameLimit: 2, byteLimit: 64)
        let key = try frame(annexB([h264SPS, h264PPS, h264IDR]), at: 1)
        _ = backlog.append(key)
        _ = backlog.append(try frame(annexB([h264Delta]), at: 2))
        let dropped = backlog.append(try frame(annexB([h264Delta]), at: 3))
        #expect(dropped == 3)
        #expect(backlog.popFirst() == nil)
        #expect(backlog.append(try frame(annexB([h264Delta]), at: 4)) == 1)
        #expect(backlog.append(try frame(annexB([h264IDR]), at: 5)) == 0)
        let next = backlog.popFirst()
        let resumed = try #require(next)
        #expect(resumed.captureTime == 5)
        #expect(resumed.restartDecoder)
        #expect(resumed.packet.parameterSets == key.packet.parameterSets)
        _ = backlog.append(try frame(annexB([h264Delta]), at: 6))
        #expect(backlog.popFirst()?.restartDecoder == false)
    }

    @Test func streamResetDropsQueuedFramesAndDoesNotReusePreviousFormat() throws {
        var backlog = VideoBacklog(frameLimit: 2, byteLimit: 64)
        _ = backlog.append(try frame(annexB([h264SPS, h264PPS, h264IDR]), at: 1))
        backlog.clear()
        #expect(backlog.popFirst() == nil)
        _ = backlog.append(try frame(annexB([h264IDR]), at: 2))
        #expect(backlog.popFirst() == nil)
        _ = backlog.append(try frame(annexB([h264SPS, h264PPS, h264IDR]), at: 3))
        #expect(backlog.popFirst()?.captureTime == 3)
    }

    @Test func byteLimitAlsoBoundsLargeKeyFrames() throws {
        var backlog = VideoBacklog(frameLimit: 10, byteLimit: 32)
        _ = backlog.append(try frame(annexB([h264SPS, h264PPS, h264IDR]), at: 1))
        let largeKey = annexB([h264IDR + Array(repeating: 0xff, count: 40)])
        #expect(backlog.append(try frame(largeKey, at: 2)) == 2)
        #expect(backlog.popFirst() == nil)
        _ = backlog.append(try frame(annexB([h264IDR]), at: 3))
        #expect(backlog.popFirst()?.captureTime == 3)
    }

    @Test func overrunKeepsTheNewestDecodableGroupInsteadOfFreezingUntilAnotherKeyFrame() throws {
        var backlog = VideoBacklog(frameLimit: 4, byteLimit: 128)
        let key = try frame(annexB([h264SPS, h264PPS, h264IDR]), at: 1)
        _ = backlog.append(key)
        _ = backlog.append(try frame(annexB([h264Delta]), at: 2))
        _ = backlog.append(try frame(annexB([h264IDR]), at: 3))
        _ = backlog.append(try frame(annexB([h264Delta]), at: 4))
        let dropped = backlog.append(try frame(annexB([h264Delta]), at: 5))
        #expect(dropped == 2)
        let first = backlog.popFirst()
        #expect(first?.captureTime == 3)
        #expect(first?.packet.parameterSets == key.packet.parameterSets)
        #expect(first?.restartDecoder == true)
        #expect(backlog.popFirst()?.captureTime == 4)
        #expect(backlog.popFirst()?.captureTime == 5)
    }

    @Test func lateQueueJumpsToAnIncomingKeyFrameBeforeItFills() throws {
        var backlog = VideoBacklog(frameLimit: 12, byteLimit: 128, delayLimit: 0.09)
        let key = try frame(annexB([h264SPS, h264PPS, h264IDR]), at: 1)
        _ = backlog.append(key, at: 1)
        _ = backlog.append(try frame(annexB([h264Delta]), at: 2), at: 1.09)
        let dropped = backlog.append(try frame(annexB([h264IDR]), at: 3), at: 1.12)
        #expect(dropped == 2)
        let first = backlog.popFirst()
        #expect(first?.captureTime == 3)
        #expect(first?.restartDecoder == true)
        #expect(first?.packet.parameterSets == key.packet.parameterSets)
    }

    private func frame(_ data: Data, at time: UInt64) throws -> VideoBacklog.Frame {
        let packet = try #require(VideoPacketParser.parse(data, codec: .h264))
        return .init(packet: packet, codec: .h264, captureTime: time, bytes: data.count)
    }
}
