import Foundation
import Network
import Testing
import MirrorCore

/// Watches the local network for `_airplay._tcp` services.
private final class BonjourProbe {
    private let browser = NWBrowser(for: .bonjour(type: "_airplay._tcp", domain: nil), using: NWParameters())
    private let lock = NSLock()
    private var names = Set<String>()

    init() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = Set(results.compactMap { result -> String? in
                if case let .service(name, _, _, _) = result.endpoint { return name }
                return nil
            })
            guard let self else { return }
            self.lock.withLock { self.names = found }
        }
        browser.start(queue: .global())
    }

    deinit {
        browser.cancel()
    }

    /// True once `name` is advertised (or no longer advertised) within `seconds`.
    func waits(for name: String, advertised: Bool, within seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let present = lock.withLock { names.contains(name) }
            if present == advertised { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}

private func openRTSP(port: UInt16) throws -> Int32 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    var noSignal: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        let failure = POSIXError(.init(rawValue: errno) ?? .EIO)
        close(descriptor)
        throw failure
    }
    return descriptor
}

/// Sends one RTSP request over loopback and returns the response.
private func rtspResponse(to request: String, port: UInt16) throws -> Data {
    let descriptor = try openRTSP(port: port)
    defer { close(descriptor) }
    return try rtspResponse(to: request, descriptor: descriptor)
}

private func rtspResponse(to request: String, descriptor: Int32) throws -> Data {
    let bytes = Array(request.utf8)
    guard send(descriptor, bytes, bytes.count, 0) == bytes.count else { throw POSIXError(.EIO) }
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 16384)
    while response.count < 65536 {
        let count = recv(descriptor, &buffer, buffer.count, 0)
        if count <= 0 { break }
        response.append(contentsOf: buffer[0..<count])
        if let boundary = response.range(of: Data("\r\n\r\n".utf8)) {
            let header = String(decoding: response[..<boundary.lowerBound], as: UTF8.self)
            let length = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            if response.count - boundary.upperBound >= length { break }
        }
    }
    return response
}

@Suite(.serialized) struct AirPlayReceiverTests {
    private func uniqueName() -> String {
        "VPV Unit Test \(UInt32.random(in: 100_000...999_999))"
    }

    @Test func randomDeviceIDIsALocallyAdministeredUnicastAddress() {
        let first = AirPlayReceiver.randomDeviceID()
        #expect(first.count == 6)
        #expect(first.first.map { $0 & 0x03 } == 0x02)
        #expect(first != AirPlayReceiver.randomDeviceID())
    }

    @Test func clockAdvancesInNanoseconds() async throws {
        let before = AirPlayReceiver.now()
        try await Task.sleep(nanoseconds: 20_000_000)
        let elapsed = AirPlayReceiver.now() &- before
        #expect(elapsed >= 15_000_000)
        #expect(elapsed < 2_000_000_000)
    }

    @Test func advertisesItsNameWhileRunningAndWithdrawsItWhenStopped() async throws {
        let name = uniqueName()
        let probe = BonjourProbe()
        let receiver = try AirPlayReceiver(
            configuration: .init(name: name, deviceID: AirPlayReceiver.randomDeviceID()), events: .init())
        #expect(receiver.port != 0)
        #expect(await probe.waits(for: name, advertised: true, within: 10))
        receiver.stop()
        #expect(await probe.waits(for: name, advertised: false, within: 10))
    }

    @Test func answersASendersFirstRequestWithItsDescription() throws {
        let name = uniqueName()
        let receiver = try AirPlayReceiver(
            configuration: .init(name: name, deviceID: AirPlayReceiver.randomDeviceID()), events: .init())
        defer { receiver.stop() }
        // Every AirPlay session opens with this request; the answer is a property list describing the receiver.
        let response = try rtspResponse(
            to: "GET /info RTSP/1.0\r\nCSeq: 0\r\nUser-Agent: AirPlay/1015.5.1\r\n\r\n", port: receiver.port)
        #expect(response.starts(with: Data("RTSP/1.0 200 OK".utf8)))
        #expect(response.range(of: Data(name.utf8)) != nil)
    }

    @Test func discoveryRequestDoesNotReplaceAnExistingControlConnection() throws {
        let receiver = try AirPlayReceiver(
            configuration: .init(name: uniqueName(), deviceID: AirPlayReceiver.randomDeviceID()), events: .init())
        defer { receiver.stop() }
        let control = try openRTSP(port: receiver.port)
        defer { close(control) }
        let ok = Data("RTSP/1.0 200 OK".utf8)
        let first = try rtspResponse(to: "POST /feedback RTSP/1.0\r\nCSeq: 1\r\n\r\n", descriptor: control)
        try #require(first.starts(with: ok))
        let discovery = try rtspResponse(to: "GET /info RTSP/1.0\r\nCSeq: 0\r\n\r\n", port: receiver.port)
        try #require(discovery.starts(with: ok))
        let next = try? rtspResponse(to: "POST /feedback RTSP/1.0\r\nCSeq: 2\r\n\r\n", descriptor: control)
        #expect(next?.starts(with: ok) == true)
    }

    @Test func stoppingTwiceIsHarmlessAndFreesThePort() throws {
        let receiver = try AirPlayReceiver(
            configuration: .init(name: uniqueName(), deviceID: AirPlayReceiver.randomDeviceID()), events: .init())
        let port = receiver.port
        receiver.stop()
        receiver.stop()
        #expect(throws: (any Error).self) {
            _ = try rtspResponse(to: "GET /info RTSP/1.0\r\nCSeq: 0\r\n\r\n", port: port)
        }
    }

    @Test func idleReceiverStopsWithoutWaitingForBonjourTimeout() throws {
        let receiver = try AirPlayReceiver(
            configuration: .init(name: uniqueName(), deviceID: AirPlayReceiver.randomDeviceID()), events: .init())
        let clock = ContinuousClock()
        let start = clock.now
        receiver.stop()
        let elapsed = clock.now - start
        print("Idle listener stop: \(elapsed)")
        #expect(elapsed < .milliseconds(500))
    }

    @Test func discoverySocketSurvivesTheMirrorWatchdog() async throws {
        var configuration = AirPlayReceiver.Configuration(name: uniqueName(), deviceID: AirPlayReceiver.randomDeviceID())
        configuration.mirrorSilenceTimeout = 1
        let receiver = try AirPlayReceiver(configuration: configuration, events: .init())
        defer { receiver.stop() }
        let descriptor = try openRTSP(port: receiver.port)
        defer { close(descriptor) }
        let ok = Data("RTSP/1.0 200 OK".utf8)
        let request = "GET /info RTSP/1.0\r\nCSeq: 1\r\n\r\n"
        try #require(try rtspResponse(to: request, descriptor: descriptor).starts(with: ok))
        try await Task.sleep(for: .seconds(3))
        #expect(try rtspResponse(to: request, descriptor: descriptor).starts(with: ok))
    }

    @Test func refusesToStartWithoutAName() {
        #expect(throws: AirPlayReceiver.StartError.failed(step: 1)) {
            _ = try AirPlayReceiver(
                configuration: .init(name: "", deviceID: AirPlayReceiver.randomDeviceID()), events: .init())
        }
    }
}
