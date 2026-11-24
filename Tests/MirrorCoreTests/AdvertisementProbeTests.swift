import Foundation
import Testing
import MirrorCore

@Suite(.serialized) struct AdvertisementProbeTests {
    /// Runs one probe and waits for its report.
    private func status(of deviceID: [UInt8], timeout: TimeInterval) async -> AdvertisementStatus {
        final class Holder: @unchecked Sendable {
            var probe: AdvertisementProbe?
        }
        let holder = Holder()
        return await withCheckedContinuation { continuation in
            holder.probe = AdvertisementProbe(deviceID: deviceID, timeout: timeout, queue: .global()) { status in
                continuation.resume(returning: status)
                holder.probe = nil
            }
        }
    }

    @Test func findsARunningReceiverByItsDeviceIDAndReportsItsName() async throws {
        let name = "VPV Unit Test \(UInt32.random(in: 100_000...999_999))"
        let deviceID = AirPlayReceiver.randomDeviceID()
        let receiver = try AirPlayReceiver(configuration: .init(name: name, deviceID: deviceID), events: .init())
        defer { receiver.stop() }
        #expect(await status(of: deviceID, timeout: 10) == .visible(name: name))
    }

    @Test func reportsHiddenWhenNoReceiverHasTheDeviceID() async throws {
        // Another receiver is running, so the probe has something to tell apart.
        let receiver = try AirPlayReceiver(
            configuration: .init(name: "VPV Unit Test Other", deviceID: AirPlayReceiver.randomDeviceID()), events: .init())
        defer { receiver.stop() }
        let started = Date()
        #expect(await status(of: AirPlayReceiver.randomDeviceID(), timeout: 1.5) == .hidden)
        // It waits out the timeout before giving up, since a registration takes a moment to appear.
        #expect(Date().timeIntervalSince(started) >= 1.4)
    }

    @Test func cancelledProbeNeverReports() async throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.withLock { value = true } }
            var isSet: Bool { lock.withLock { value } }
        }
        let reported = Flag()
        let probe = AdvertisementProbe(deviceID: AirPlayReceiver.randomDeviceID(), timeout: 0.3, queue: .global()) { _ in
            reported.set()
        }
        probe.cancel()
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(!reported.isSet)
    }
}
