import Foundation
import Network

/// Whether other devices can see this app's AirPlay receiver.
public enum AdvertisementStatus: Equatable, Sendable {
    /// The receiver is listed on the local network under `name`.
    case visible(name: String)
    /// macOS has not allowed this app to use the local network.
    case blocked
    /// Browsing works, but the receiver is not listed.
    case hidden
}

/// Looks on the local network for the AirPlay receiver with a given device ID, the way a sender would.
/// Reports once, then stops.
///
/// The protocol library cannot say whether its Bonjour registration reached the network: macOS drops
/// registrations of an app without Local Network permission, and the library ignores the error.
public final class AdvertisementProbe {
    /// `kDNSServiceErr_PolicyDenied`: the system refused the request for privacy reasons.
    private static let policyDenied: DNSServiceErrorType = -65570

    private let browser: NWBrowser
    private let lock = NSLock()
    private var isFinished = false

    /// `completion` runs on `queue` with `.visible` as soon as the receiver is found,
    /// or with `.blocked` or `.hidden` after `timeout` seconds.
    public init(
        deviceID: [UInt8], timeout: TimeInterval, queue: DispatchQueue = .main,
        completion: @escaping (AdvertisementStatus) -> Void
    ) {
        // The receiver publishes its device ID in the service's TXT record, so a renamed
        // duplicate ("Name (2)") is still recognised and someone else's receiver is not.
        let wanted = deviceID.map { String(format: "%02x", $0) }.joined(separator: ":")
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil), using: NWParameters())
        let work = DispatchQueue(label: "com.eitan.AirPlayViewer.advertisement-probe")
        // Touched only on `work`.
        var wasDenied = false

        let finish: (AdvertisementStatus) -> Void = { [weak self] status in
            guard let self, self.finishOnce() else { return }
            self.browser.cancel()
            queue.async { completion(status) }
        }
        browser.stateUpdateHandler = { state in
            if case .waiting(let error) = state, case .dns(let code) = error, code == Self.policyDenied {
                wasDenied = true
            }
        }
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint,
                      case let .bonjour(record) = result.metadata,
                      record["deviceid"]?.lowercased() == wanted else { continue }
                finish(.visible(name: name))
                return
            }
        }
        browser.start(queue: work)
        work.asyncAfter(deadline: .now() + timeout) {
            finish(wasDenied ? .blocked : .hidden)
        }
    }

    deinit {
        browser.cancel()
    }

    /// Stops looking. The completion handler will not run.
    public func cancel() {
        if finishOnce() {
            browser.cancel()
        }
    }

    /// True for the first caller only.
    private func finishOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isFinished { return false }
        isFinished = true
        return true
    }
}
