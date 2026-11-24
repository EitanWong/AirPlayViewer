import Foundation
import Testing
import MirrorCore

@Suite struct ReceiverSettingsTests {
    /// A private defaults domain, removed after the test.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "vpv-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func defaultsDescribeA1080pReceiverThatAcceptsHEVC() {
        withDefaults { defaults in
            let settings = ReceiverSettings.load(from: defaults)
            #expect(settings.name == "AirPlayViewer")
            #expect(settings.allowHEVC)
            #expect(settings.width == 1920)
            #expect(settings.height == 1080)
            #expect(settings.maxFPS == 60)
        }
    }

    @Test func deviceIDIsCreatedOnceAndThenReused() {
        withDefaults { defaults in
            let first = ReceiverSettings.load(from: defaults)
            let second = ReceiverSettings.load(from: defaults)
            #expect(first.deviceID.count == 6)
            #expect(first.deviceID == second.deviceID)
            // Locally administered, not multicast: such an address cannot collide with real hardware.
            #expect(first.deviceID.first.map { $0 & 0x03 } == 0x02)
        }
    }

    @Test func differentInstallationsGetDifferentDeviceIDs() {
        withDefaults { first in
            withDefaults { second in
                #expect(ReceiverSettings.load(from: first).deviceID != ReceiverSettings.load(from: second).deviceID)
            }
        }
    }

    @Test func storedValuesOverrideTheDefaults() {
        withDefaults { defaults in
            defaults.set("Studio Mac", forKey: ReceiverSettings.Key.name)
            defaults.set(false, forKey: ReceiverSettings.Key.allowHEVC)
            defaults.set(3840, forKey: ReceiverSettings.Key.width)
            defaults.set(2160, forKey: ReceiverSettings.Key.height)
            defaults.set(30, forKey: ReceiverSettings.Key.maxFPS)
            defaults.set("02:11:22:33:44:55", forKey: ReceiverSettings.Key.deviceID)
            let settings = ReceiverSettings.load(from: defaults)
            #expect(settings == ReceiverSettings(
                name: "Studio Mac", deviceID: [0x02, 0x11, 0x22, 0x33, 0x44, 0x55],
                allowHEVC: false, width: 3840, height: 2160, maxFPS: 30))
        }
    }

    @Test func unusableStoredValuesFallBackToTheDefaults() {
        withDefaults { defaults in
            defaults.set("   ", forKey: ReceiverSettings.Key.name)
            defaults.set(-5, forKey: ReceiverSettings.Key.width)
            defaults.set(0, forKey: ReceiverSettings.Key.maxFPS)
            defaults.set("not an address", forKey: ReceiverSettings.Key.deviceID)
            let settings = ReceiverSettings.load(from: defaults)
            #expect(settings.name == "AirPlayViewer")
            #expect(settings.width == 1920)
            #expect(settings.maxFPS == 60)
            #expect(settings.deviceID.count == 6)
            // The replacement is stored, so the next launch does not change identity again.
            #expect(ReceiverSettings.load(from: defaults).deviceID == settings.deviceID)
        }
    }

    @Test func receiverNameFitsBonjourAndPreservesWholeCharacters() {
        let name = ReceiverSettings.normalizedName("  " + String(repeating: "镜", count: 30) + "  ")
        #expect(name == String(repeating: "镜", count: 16))
        #expect(name.utf8.count <= 50)
        #expect(ReceiverSettings.normalizedName(".local") == ReceiverSettings.defaultName)
        #expect(ReceiverSettings.normalizedName("Studio\u{0000} Mac.local") == "Studio Mac")
    }
}

@Suite struct StreamStatisticsTests {
    @Test func nothingIsReportedBeforeTheIntervalHasPassed() {
        var statistics = StreamStatistics(interval: 5)
        #expect(statistics.record(bytes: 1000, ageNanoseconds: nil, at: 100) == nil)
        #expect(statistics.record(bytes: 1000, ageNanoseconds: nil, at: 104.9) == nil)
    }

    @Test func reportCoversTheFramesOfTheInterval() throws {
        var statistics = StreamStatistics(interval: 5)
        // 150 frames of 2 500 bytes in the five seconds after the first frame: 30 per second, 600 kbit/s.
        _ = statistics.record(bytes: 2500, ageNanoseconds: 40_000_000, at: 100)
        for index in 1..<150 {
            let age: UInt64 = index == 75 ? 90_000_000 : 40_000_000
            #expect(statistics.record(bytes: 2500, ageNanoseconds: age, at: 100 + Double(index) / 30) == nil)
        }
        let closing = statistics.record(bytes: 2500, ageNanoseconds: 40_000_000, at: 105)
        let report = try #require(closing)
        #expect(abs(report.framesPerSecond - 30) < 0.01)
        #expect(abs(report.kilobitsPerSecond - 600) < 0.01)
        #expect(report.maxAgeMilliseconds == 90)
        let mean = try #require(report.meanAgeMilliseconds)
        #expect(abs(mean - (149 * 40 + 90) / 150.0) < 0.001)
    }

    @Test func ageIsLeftOutWhenTheSenderClockIsUnknown() throws {
        var statistics = StreamStatistics(interval: 1)
        _ = statistics.record(bytes: 10, ageNanoseconds: nil, at: 0)
        let closing = statistics.record(bytes: 10, ageNanoseconds: nil, at: 1)
        let report = try #require(closing)
        #expect(report.meanAgeMilliseconds == nil)
        #expect(report.maxAgeMilliseconds == nil)
    }

    @Test func eachReportStartsANewInterval() throws {
        var statistics = StreamStatistics(interval: 1)
        _ = statistics.record(bytes: 10, ageNanoseconds: nil, at: 0)
        let first = statistics.record(bytes: 10, ageNanoseconds: nil, at: 1)
        #expect(first != nil)
        #expect(statistics.record(bytes: 10, ageNanoseconds: nil, at: 1.5) == nil)
        let closing = statistics.record(bytes: 10, ageNanoseconds: nil, at: 2)
        let second = try #require(closing)
        // The frame that closed the first interval opens the second: two more frames in one second.
        #expect(abs(second.framesPerSecond - 2) < 0.01)
    }

    @Test func resetStartsOver() {
        var statistics = StreamStatistics(interval: 1)
        _ = statistics.record(bytes: 10, ageNanoseconds: nil, at: 0)
        statistics.reset()
        #expect(statistics.record(bytes: 10, ageNanoseconds: nil, at: 5) == nil)
    }
}
