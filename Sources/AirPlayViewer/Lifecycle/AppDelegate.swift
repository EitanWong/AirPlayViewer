import AppKit
import MirrorCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: PanelController?
    private var session: MirrorSession?
    private var pattern: DiagnosticPattern?
    private var statusItem: NSStatusItem?
    private var preferencesWindow: NSWindow?
    private lazy var preferences = ReceiverPreferences(defaults: .standard)
    private var sessionName: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIdentity.migratePreferences(.standard)
        let controller = PanelController()
        panelController = controller
        makeStatusItem()
        configureAppearanceAndPresentation()

        // `-DiagnosticPattern YES` on the command line: show a test picture through the decode and display
        // path. The pattern stands in for a sender, so the receiver stays off and nothing is advertised.
        if UserDefaults.standard.bool(forKey: "DiagnosticPattern") {
            let session = makeSession()
            let pattern = DiagnosticPattern { [weak session] packet, codec in
                session?.ingest(packet, codec: codec, captureTime: AirPlayReceiver.now())
            }
            pattern.start()
            self.pattern = pattern
            if UserDefaults.standard.bool(forKey: "DiagnosticSettings") { showPreferences() }
        } else {
            makeSession().start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pattern?.stop()
        session?.stop()
        MirrorSession.finishStopping()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        panelController?.fitToScreen()
    }

    private func makeSession() -> MirrorSession {
        session?.onStateChange = nil
        session?.onPicture = nil
        session?.onAspect = nil
        session?.onSenderActivity = nil
        session?.stop()
        let settings = ReceiverSettings.load(from: .standard)
        let session = MirrorSession(settings: settings)
        sessionName = settings.name
        session.setPresentationEnabled(preferences.presentationEnabled)
        session.onStateChange = { [weak self] state in
            guard let self else { return }
            self.panelController?.apply(state)
            if case .waiting = state, self.sessionName != self.preferences.name {
                DispatchQueue.main.async { [weak self] in self?.updateReceiverName() }
            }
        }
        session.onPicture = { [weak self] picture in
            self?.panelController?.mirrorView.show(picture)
        }
        session.onAspect = { [weak self] aspect in
            self?.panelController?.updateAspect(aspect)
        }
        session.onSenderActivity = { [weak self] time in
            self?.panelController?.presentation.senderInput(at: time)
        }
        self.session = session
        return session
    }

    private func configureAppearanceAndPresentation() {
        let icon = preferences.iconImage
        statusItem?.button?.image = icon
        statusItem?.button?.setAccessibilityLabel(L10n.windowTitle)
        panelController?.setReceiverIcon(icon)
        session?.setPresentationEnabled(preferences.presentationEnabled)
        panelController?.presentation.configure(enabled: preferences.presentationEnabled, amount: preferences.zoomPercent / 100)
        panelController?.refreshPresentation()
    }

    private func updateReceiverName() {
        guard pattern == nil, sessionName != preferences.name, session?.isMirroring != true else { return }
        makeSession().start()
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        let show = NSMenuItem(title: L10n.showWindow, action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let settings = NSMenuItem(title: L10n.preferences, action: #selector(showPreferences), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.quit, action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func showWindow() {
        panelController?.showWindow(nil)
        panelController?.window?.makeKeyAndOrderFront(nil)
        panelController?.refreshPresentation()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showPreferences() {
        if let preferencesWindow, preferencesWindow.isVisible {
            preferencesWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.preferences
        window.contentMinSize = NSSize(width: 360, height: 200)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: ReceiverPreferencesView(
            draft: preferences,
            save: { [weak self, weak window] settings in
                guard let self else { return }
                self.preferences = settings
                settings.save(to: .standard)
                self.configureAppearanceAndPresentation()
                self.updateReceiverName()
                window?.close()
            },
            cancel: { [weak window] in window?.close() }
        ))
        preferencesWindow = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
