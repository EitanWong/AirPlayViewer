import Foundation
import Testing
import MirrorCore

private let startCode: [UInt8] = [0, 0, 0, 1]

/// An Annex B packet as the receiver delivers it.
func annexB(_ nalUnits: [[UInt8]]) -> Data {
    Data(nalUnits.flatMap { startCode + $0 })
}

/// NAL units behind 4-byte big-endian lengths, as decoders take them.
func lengthPrefixed(_ nalUnits: [[UInt8]]) -> Data {
    Data(nalUnits.flatMap { unit -> [UInt8] in
        let n = UInt32(unit.count)
        return [UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)] + unit
    })
}

// H.264 NAL units: the low five bits of the first byte are the type.
let h264SPS: [UInt8] = [0x67, 0x64, 0x00, 0x28]
let h264PPS: [UInt8] = [0x68, 0xee, 0x3c]
let h264IDR: [UInt8] = [0x65, 0x88, 0x84, 0x21, 0xa0]
let h264Delta: [UInt8] = [0x41, 0x9a, 0x24]
let h264SEI: [UInt8] = [0x06, 0x05, 0x04]

// HEVC NAL units: bits 1-6 of the first byte are the type.
let hevcVPS: [UInt8] = [0x40, 0x01, 0x0c]
let hevcSPS: [UInt8] = [0x42, 0x01, 0x01, 0x60]
let hevcPPS: [UInt8] = [0x44, 0x01, 0xc0]
let hevcIDR: [UInt8] = [0x26, 0x01, 0xaf, 0x09]
let hevcCRA: [UInt8] = [0x2a, 0x01, 0xaf]
let hevcDelta: [UInt8] = [0x02, 0x01, 0xd0]

@Suite struct VideoPacketParserTests {
    @Test func h264KeyFramePacketYieldsParameterSetsAndLengthPrefixedSample() throws {
        let packet = try #require(VideoPacketParser.parse(annexB([h264SPS, h264PPS, h264IDR]), codec: .h264))
        #expect(packet.parameterSets == ParameterSets(codec: .h264, sps: [Data(h264SPS)], pps: [Data(h264PPS)]))
        #expect(packet.sample == lengthPrefixed([h264IDR]))
        #expect(packet.isKeyFrame)
    }

    @Test func h264DeltaFrameHasNoParameterSetsAndIsNotAKeyFrame() throws {
        let packet = try #require(VideoPacketParser.parse(annexB([h264Delta]), codec: .h264))
        #expect(packet.parameterSets == nil)
        #expect(packet.sample == lengthPrefixed([h264Delta]))
        #expect(!packet.isKeyFrame)
    }

    @Test func otherNALUnitsStayWithTheFrameInOrder() throws {
        let packet = try #require(VideoPacketParser.parse(annexB([h264SEI, h264IDR]), codec: .h264))
        #expect(packet.sample == lengthPrefixed([h264SEI, h264IDR]))
        #expect(packet.isKeyFrame)
    }

    @Test func hevcKeyFramePacketYieldsThreeParameterSets() throws {
        let packet = try #require(VideoPacketParser.parse(annexB([hevcVPS, hevcSPS, hevcPPS, hevcIDR]), codec: .hevc))
        #expect(packet.parameterSets == ParameterSets(
            codec: .hevc, vps: [Data(hevcVPS)], sps: [Data(hevcSPS)], pps: [Data(hevcPPS)]))
        #expect(packet.parameterSets?.ordered == [Data(hevcVPS), Data(hevcSPS), Data(hevcPPS)])
        #expect(packet.sample == lengthPrefixed([hevcIDR]))
        #expect(packet.isKeyFrame)
    }

    @Test func hevcCleanRandomAccessFrameIsAKeyFrame() throws {
        let packet = try #require(VideoPacketParser.parse(annexB([hevcCRA]), codec: .hevc))
        #expect(packet.isKeyFrame)
    }

    @Test func hevcTrailingFrameIsNotAKeyFrame() throws {
        let packet = try #require(VideoPacketParser.parse(annexB([hevcDelta]), codec: .hevc))
        #expect(packet.parameterSets == nil)
        #expect(packet.sample == lengthPrefixed([hevcDelta]))
        #expect(!packet.isKeyFrame)
    }

    @Test func h264BytesAreNotReadAsHEVCTypes() throws {
        // 0x65 is an IDR slice in H.264 but type 50 (reserved) in HEVC.
        let packet = try #require(VideoPacketParser.parse(annexB([h264IDR]), codec: .hevc))
        #expect(!packet.isKeyFrame)
    }

    @Test func parameterSetsOnlyPacketHasAnEmptySample() throws {
        let packet = try #require(VideoPacketParser.parse(annexB([h264SPS, h264PPS]), codec: .h264))
        #expect(packet.parameterSets != nil)
        #expect(packet.sample.isEmpty)
        #expect(!packet.isKeyFrame)
    }

    @Test func incompleteParameterSetsAreNotReported() throws {
        let packet = try #require(VideoPacketParser.parse(annexB([h264SPS, h264IDR]), codec: .h264))
        #expect(packet.parameterSets == nil)
        #expect(packet.sample == lengthPrefixed([h264IDR]))
    }

    @Test func packetTheReceiverMarkedAsDamagedIsRejected() {
        // The protocol library overwrites the first byte with 1 when decryption produced garbage.
        var data = annexB([h264IDR])
        data[0] = 1
        #expect(VideoPacketParser.parse(data, codec: .h264) == nil)
    }

    @Test func emptyAndTruncatedPacketsAreRejected() {
        #expect(VideoPacketParser.parse(Data(), codec: .h264) == nil)
        #expect(VideoPacketParser.parse(Data([0, 0, 0, 1]), codec: .h264) == nil)
        #expect(VideoPacketParser.parse(Data([0, 0, 0]), codec: .h264) == nil)
    }

    @Test func nalUnitWithForbiddenBitSetIsRejected() {
        #expect(VideoPacketParser.parse(annexB([[0xe5, 0x88]]), codec: .h264) == nil)
    }

    @Test func parsingDoesNotDependOnWhereTheDataStarts() throws {
        // A slice of a larger Data has non-zero start index.
        let padded = Data([9, 9, 9]) + annexB([h264SPS, h264PPS, h264IDR])
        let packet = try #require(VideoPacketParser.parse(padded.dropFirst(3), codec: .h264))
        #expect(packet.sample == lengthPrefixed([h264IDR]))
    }
}
