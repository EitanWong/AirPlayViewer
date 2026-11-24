import CoreVideo
import Testing
@testable import MirrorCore

@Suite struct FrameActivityTests {
    @Test func staticPictureIsQuietButChangedPictureIsActive() throws {
        var activity = FrameActivity()
        let dark = try picture(level: 0)
        let light = try picture(level: 120)
        let first = activity.record(dark, at: 1)
        let tooEarly = activity.record(light, at: 1.03)
        let changed = activity.record(light, at: 1.12)
        let still = activity.record(light, at: 1.24)
        #expect(!first)
        #expect(!tooEarly)
        #expect(changed)
        #expect(!still)
        activity = FrameActivity()
        let afterReset = activity.record(dark, at: 2)
        #expect(!afterReset)
    }

    private func picture(level: UInt8) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 48, 32, kCVPixelFormatType_32BGRA, nil, &result) == kCVReturnSuccess)
        let buffer = try #require(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        base.initializeMemory(as: UInt8.self, repeating: level, count: CVPixelBufferGetBytesPerRow(buffer) * 32)
        return buffer
    }
}
