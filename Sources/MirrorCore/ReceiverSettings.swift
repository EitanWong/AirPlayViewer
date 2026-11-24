import Foundation

/// How the receiver presents itself, read from user defaults so it can be changed without rebuilding:
/// `defaults write com.eitan.AirPlayViewer ReceiverName "Studio Mac"`.
public struct ReceiverSettings: Equatable, Sendable {
    public static let defaultName = "AirPlayViewer"

    public enum Key {
        public static let name = "ReceiverName"
        public static let deviceID = "ReceiverDeviceID"
        public static let allowHEVC = "ReceiverAllowHEVC"
        public static let width = "ReceiverWidth"
        public static let height = "ReceiverHeight"
        public static let maxFPS = "ReceiverMaxFPS"
    }

    public var name: String
    public var deviceID: [UInt8]
    public var allowHEVC: Bool
    public var width: Int
    public var height: Int
    public var maxFPS: Int

    public init(name: String, deviceID: [UInt8], allowHEVC: Bool, width: Int, height: Int, maxFPS: Int) {
        self.name = name
        self.deviceID = deviceID
        self.allowHEVC = allowHEVC
        self.width = width
        self.height = height
        self.maxFPS = maxFPS
    }

    /// Reads the settings. On first use it creates a device ID and stores it, so senders keep seeing the same receiver.
    public static func load(from defaults: UserDefaults) -> ReceiverSettings {
        let name = normalizedName(defaults.string(forKey: Key.name) ?? "")
        func positive(_ key: String, default fallback: Int) -> Int {
            let value = defaults.integer(forKey: key)
            return value > 0 ? value : fallback
        }
        let deviceID: [UInt8]
        if let stored = defaults.string(forKey: Key.deviceID).flatMap(parseDeviceID) {
            deviceID = stored
        } else {
            deviceID = AirPlayReceiver.randomDeviceID()
            defaults.set(deviceID.map { String(format: "%02x", $0) }.joined(separator: ":"), forKey: Key.deviceID)
        }
        return ReceiverSettings(
            name: name,
            deviceID: deviceID,
            // `bool(forKey:)` also understands "NO" from the command line; absent means allowed.
            allowHEVC: defaults.object(forKey: Key.allowHEVC) == nil ? true : defaults.bool(forKey: Key.allowHEVC),
            width: positive(Key.width, default: 1920),
            height: positive(Key.height, default: 1080),
            maxFPS: positive(Key.maxFPS, default: 60))
    }

    public static func normalizedName(_ name: String) -> String {
        let sanitized = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let prefix = sanitized.range(of: ".local").map { String(sanitized[..<$0.lowerBound]) } ?? sanitized
        var result = ""
        var bytes = 0
        for character in prefix.trimmingCharacters(in: .whitespacesAndNewlines) {
            let count = String(character).utf8.count
            // DNS-SD labels allow 63 bytes, including RAOP's thirteen-byte device ID prefix.
            guard bytes + count <= 50 else { break }
            result.append(character)
            bytes += count
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? defaultName : result
    }

    /// Six colon-separated hexadecimal bytes, such as `02:11:22:33:44:55`.
    private static func parseDeviceID(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        let bytes = parts.compactMap { $0.count == 2 ? UInt8($0, radix: 16) : nil }
        return bytes.count == 6 ? bytes : nil
    }
}
