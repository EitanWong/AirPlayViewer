import AppKit
import Testing
@testable import AirPlayViewer

@MainActor
@Suite(.serialized)
struct PanelVisibilityTests {
    @Test func networkRecoveryUsesANativeGlassButton() throws {
        _ = NSApplication.shared
        let panel = PanelController()
        defer { panel.close() }
        let content = try #require(panel.window?.contentView)
        let button = try #require(allSubviews(of: content).compactMap { $0 as? NSButton }.first {
            $0.title == L10n.openSettings
        })
        panel.apply(.needsLocalNetwork)
        #expect(!button.isHiddenOrHasHiddenAncestor)
        #expect(button.bezelStyle == .glass)
        panel.apply(.live(sender: "Test sender"))
        #expect(button.isHiddenOrHasHiddenAncestor)
    }

    @Test func onlyDecodedVideoAutomaticallyShowsThePanel() {
        _ = NSApplication.shared
        let panel = PanelController()
        defer { panel.close() }

        panel.apply(.starting)
        #expect(panel.window?.isVisible == false)
        panel.apply(.waiting(receiverName: "Receiver"))
        #expect(panel.window?.isVisible == false)
        panel.apply(.needsLocalNetwork)
        #expect(panel.window?.isVisible == false)
        panel.apply(.failed("Test error"))
        #expect(panel.window?.isVisible == false)

        panel.apply(.live(sender: "Test sender"))
        #expect(panel.window?.isVisible == true)
        panel.apply(.waiting(receiverName: "Receiver"))
        #expect(panel.window?.isVisible == false)
    }

    @Test func manuallyClosingDuringVideoOnlySuppressesThatSession() {
        _ = NSApplication.shared
        let panel = PanelController()
        defer { panel.close() }

        panel.apply(.live(sender: "Test sender"))
        #expect(panel.window?.isVisible == true)
        panel.close()
        panel.apply(.live(sender: "Test sender"))
        #expect(panel.window?.isVisible == false)

        panel.apply(.waiting(receiverName: "Receiver"))
        panel.apply(.live(sender: "Another sender"))
        #expect(panel.window?.isVisible == true)
    }

    @Test func explicitlyOpenedStatusStaysVisibleWhileIdle() {
        _ = NSApplication.shared
        let panel = PanelController()
        defer { panel.close() }

        panel.window?.orderFrontRegardless()
        panel.apply(.waiting(receiverName: "Receiver"))
        #expect(panel.window?.isVisible == true)
        panel.apply(.needsLocalNetwork)
        #expect(panel.window?.isVisible == true)
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }
}
