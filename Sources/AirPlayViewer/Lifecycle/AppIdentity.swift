import Foundation
import MirrorCore

enum AppIdentity {
    private static let legacyName = "VisionProViewer"
    private static let migrationKey = "DidMigrateVisionProViewerPreferences"

    static func migratePreferences(
        _ defaults: UserDefaults,
        legacy: [String: Any]? = UserDefaults.standard.persistentDomain(forName: "com.eitan.VisionProViewer")
    ) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        if let legacy {
            let keys = [
                ReceiverSettings.Key.name, ReceiverSettings.Key.deviceID, ReceiverSettings.Key.allowHEVC,
                ReceiverSettings.Key.width, ReceiverSettings.Key.height, ReceiverSettings.Key.maxFPS,
                ReceiverPreferences.iconKey, ReceiverPreferences.presentationKey, ReceiverPreferences.zoomKey
            ]
            for key in keys where defaults.object(forKey: key) == nil {
                guard let value = legacy[key] else { continue }
                if key == ReceiverSettings.Key.name, value as? String == legacyName { continue }
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: migrationKey)
    }

    static func receiverKey(in support: URL) throws -> URL {
        let manager = FileManager.default
        let directory = support.appendingPathComponent("AirPlayViewer", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = directory.appendingPathComponent("receiver-key.pem")
        let oldKey = support.appendingPathComponent(legacyName, isDirectory: true)
            .appendingPathComponent("receiver-key.pem")
        if !manager.fileExists(atPath: key.path), manager.fileExists(atPath: oldKey.path) {
            try manager.copyItem(at: oldKey, to: key)
        }
        return key
    }
}
