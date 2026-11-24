import Foundation

enum L10n {
    static var windowTitle: String { String(localized: "window.title", bundle: .module) }
    static var waiting: String { String(localized: "status.waiting", bundle: .module) }
    static var receiverFailed: String { String(localized: "status.receiverFailed", bundle: .module) }
    static var showWindow: String { String(localized: "menu.showWindow", bundle: .module) }
    static var quit: String { String(localized: "menu.quit", bundle: .module) }
    static var unknownSender: String { String(localized: "sender.unknown", bundle: .module) }
    static var localNetworkTitle: String { String(localized: "localNetwork.title", bundle: .module) }
    static var localNetworkHint: String { String(localized: "localNetwork.hint", bundle: .module) }
    static var openSettings: String { String(localized: "localNetwork.openSettings", bundle: .module) }
    static var startingReceiver: String { String(localized: "status.starting", bundle: .module) }
    static var preferences: String { String(localized: "menu.preferences", bundle: .module) }
    static var receiverSection: String { String(localized: "settings.receiver", bundle: .module) }
    static var receiverName: String { String(localized: "settings.receiverName", bundle: .module) }
    static var receiverIcon: String { String(localized: "settings.receiverIcon", bundle: .module) }
    static var chooseIcon: String { String(localized: "settings.chooseIcon", bundle: .module) }
    static var resetIcon: String { String(localized: "settings.resetIcon", bundle: .module) }
    static var presentationSection: String { String(localized: "settings.presentation", bundle: .module) }
    static var presentationEnabled: String { String(localized: "settings.presentationEnabled", bundle: .module) }
    static var presentationZoom: String { String(localized: "settings.presentationZoom", bundle: .module) }
    static var iconImportFailed: String { String(localized: "settings.iconImportFailed", bundle: .module) }
    static var cancel: String { String(localized: "button.cancel", bundle: .module) }
    static var save: String { String(localized: "button.save", bundle: .module) }
    static var ok: String { String(localized: "button.ok", bundle: .module) }

    static func waitingHint(receiverName: String) -> String {
        String(format: String(localized: "status.waitingHint", bundle: .module), receiverName)
    }

    static func receiverFailedHint(code: Int) -> String {
        String(format: String(localized: "status.receiverFailedHint", bundle: .module), code)
    }
}
