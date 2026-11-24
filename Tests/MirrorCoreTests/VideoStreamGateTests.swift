import Foundation
import Testing
import MirrorCore

@Suite struct VideoStreamGateTests {
    private let sets = ParameterSets(codec: .h264, sps: [Data(h264SPS)], pps: [Data(h264PPS)])
    private let otherSets = ParameterSets(codec: .h264, sps: [Data([0x67, 0x42])], pps: [Data(h264PPS)])

    private func keyFrame(_ parameterSets: ParameterSets? = nil) -> VideoPacket {
        VideoPacket(parameterSets: parameterSets, sample: lengthPrefixed([h264IDR]), isKeyFrame: true)
    }

    private var deltaFrame: VideoPacket {
        VideoPacket(parameterSets: nil, sample: lengthPrefixed([h264Delta]), isKeyFrame: false)
    }

    @Test func framesBeforeAnyParameterSetsAreDropped() {
        var gate = VideoStreamGate()
        #expect(gate.decide(deltaFrame) == .drop)
        #expect(gate.decide(keyFrame()) == .drop)
    }

    @Test func firstKeyFrameWithParameterSetsConfiguresTheDecoder() {
        var gate = VideoStreamGate()
        #expect(gate.decide(keyFrame(sets)) == .decode(newFormat: sets))
    }

    @Test func framesAfterTheKeyFrameDecodeWithoutReconfiguring() {
        var gate = VideoStreamGate()
        _ = gate.decide(keyFrame(sets))
        #expect(gate.decide(deltaFrame) == .decode(newFormat: nil))
        #expect(gate.decide(keyFrame()) == .decode(newFormat: nil))
    }

    @Test func parameterSetsSentAheadOfTheKeyFrameAreRemembered() {
        var gate = VideoStreamGate()
        let setsOnly = VideoPacket(parameterSets: sets, sample: Data(), isKeyFrame: false)
        #expect(gate.decide(setsOnly) == .drop)
        #expect(gate.decide(deltaFrame) == .drop)
        #expect(gate.decide(keyFrame()) == .decode(newFormat: sets))
    }

    @Test func repeatedIdenticalParameterSetsDoNotReconfigure() {
        var gate = VideoStreamGate()
        _ = gate.decide(keyFrame(sets))
        #expect(gate.decide(keyFrame(sets)) == .decode(newFormat: nil))
    }

    @Test func changedParameterSetsReconfigureAtTheNextKeyFrame() {
        var gate = VideoStreamGate()
        _ = gate.decide(keyFrame(sets))
        let setsOnly = VideoPacket(parameterSets: otherSets, sample: Data(), isKeyFrame: false)
        #expect(gate.decide(setsOnly) == .drop)
        #expect(gate.decide(deltaFrame) == .drop)
        #expect(gate.decide(keyFrame()) == .decode(newFormat: otherSets))
    }

    @Test func afterResetNothingDecodesUntilNewParameterSetsArrive() {
        var gate = VideoStreamGate()
        _ = gate.decide(keyFrame(sets))
        gate.reset()
        #expect(gate.decide(deltaFrame) == .drop)
        #expect(gate.decide(keyFrame()) == .drop)
        #expect(gate.decide(keyFrame(sets)) == .decode(newFormat: sets))
    }

    @Test func requiringAKeyFrameDropsDeltaFramesButKeepsTheFormat() {
        var gate = VideoStreamGate()
        _ = gate.decide(keyFrame(sets))
        gate.requireKeyFrame()
        #expect(gate.decide(deltaFrame) == .drop)
        #expect(gate.decide(keyFrame()) == .decode(newFormat: nil))
        #expect(gate.decide(deltaFrame) == .decode(newFormat: nil))
    }
}
