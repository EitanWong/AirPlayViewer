import Foundation
import MirrorCore
import Testing
@testable import AirPlayViewer

struct AppIdentityTests {
    @Test(arguments: ["VisionProViewer", "Studio Mac"])
    func preservesCustomNamesAndIdentityButRetiresTheOldDefault(oldName: String) throws {
        let suite = "airplay-viewer-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = [
            ReceiverSettings.Key.name: oldName,
            ReceiverSettings.Key.deviceID: "02:11:22:33:44:55",
            ReceiverPreferences.presentationKey: true
        ] as [String: Any]

        AppIdentity.migratePreferences(defaults, legacy: legacy)
        #expect(ReceiverSettings.load(from: defaults).name ==
                (oldName == "VisionProViewer" ? "AirPlayViewer" : oldName))
        #expect(defaults.string(forKey: ReceiverSettings.Key.deviceID) == "02:11:22:33:44:55")
        #expect(defaults.bool(forKey: ReceiverPreferences.presentationKey))

        defaults.removeObject(forKey: ReceiverPreferences.presentationKey)
        AppIdentity.migratePreferences(defaults, legacy: legacy)
        #expect(!defaults.bool(forKey: ReceiverPreferences.presentationKey))
    }

    @Test func preservesTheReceiverKeyWithoutOverwritingANewOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacy = root.appendingPathComponent("VisionProViewer", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("Legacy test identity".utf8)
        try bytes.write(to: legacy.appendingPathComponent("receiver-key.pem"))

        let key = try AppIdentity.receiverKey(in: root)
        #expect(key.deletingLastPathComponent().lastPathComponent == "AirPlayViewer")
        #expect(try Data(contentsOf: key) == bytes)

        let next = Data("New test identity".utf8)
        try next.write(to: key, options: .atomic)
        #expect(try Data(contentsOf: AppIdentity.receiverKey(in: root)) == next)
    }
}
