import AppKit
import WindowLayout

final class PanelController: NSWindowController, NSWindowDelegate {
    static let margin: CGFloat = 16
    static let snapThreshold: CGFloat = 60
    static let minimumWidth: CGFloat = 240

    let mirrorView = MirrorView()
    let presentation = PresentationController()

    private let overlay = NSVisualEffectView()
    private let receiverIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let settingsButton = NSButton(title: "", target: nil, action: nil)
    private var snapTimer: Timer?
    private var updatingFrame = false
    private var live = false
    private(set) var aspectRatio: CGFloat = 16.0 / 9.0

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.windowTitle
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: Self.minimumWidth, height: Self.minimumWidth / aspectRatio)
        panel.contentAspectRatio = NSSize(width: aspectRatio, height: 1)

        super.init(window: panel)
        panel.delegate = self
        presentation.window = panel
        presentation.applyFrame = { [weak self] frame in self?.applyFrame(frame) }

        let content = NSView(frame: panel.contentLayoutRect)
        content.autoresizingMask = [.width, .height]
        mirrorView.frame = content.bounds
        mirrorView.autoresizingMask = [.width, .height]
        content.addSubview(mirrorView)

        overlay.frame = content.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.material = .hudWindow
        overlay.blendingMode = .withinWindow
        overlay.state = .active
        content.addSubview(overlay)

        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.textColor = .labelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 5
        settingsButton.title = L10n.openSettings
        settingsButton.bezelStyle = .glass
        settingsButton.target = self
        settingsButton.action = #selector(openLocalNetworkSettings)

        receiverIcon.imageScaling = .scaleProportionallyUpOrDown
        receiverIcon.setAccessibilityElement(false)
        let stack = NSStackView(views: [receiverIcon, statusLabel, messageLabel, settingsButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stack)
        NSLayoutConstraint.activate([
            receiverIcon.widthAnchor.constraint(equalToConstant: 20),
            receiverIcon.heightAnchor.constraint(equalToConstant: 20),
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -24),
        ])

        panel.contentView = content
        placeAtDefaultCorner()
        updateScreenLimits()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(_ state: MirrorState) {
        let wasLive = live
        if case .live = state { live = true } else { live = false }
        defer { refreshPresentation() }
        if wasLive && !live { window?.orderOut(nil) }
        switch state {
        case .starting:
            mirrorView.clear()
            showOverlay(title: L10n.startingReceiver, message: "")
        case .waiting(let receiverName):
            window?.title = L10n.windowTitle
            mirrorView.clear()
            showOverlay(title: L10n.waiting, message: L10n.waitingHint(receiverName: receiverName))
        case .needsLocalNetwork:
            window?.title = L10n.localNetworkTitle
            mirrorView.clear()
            showOverlay(title: L10n.localNetworkTitle, message: L10n.localNetworkHint, showsSettingsButton: true)
        case .live(let sender):
            window?.title = sender
            overlay.isHidden = true
            if !wasLive && window?.isVisible == false { window?.orderFrontRegardless() }
        case .failed(let message):
            window?.title = L10n.receiverFailed
            showOverlay(title: L10n.receiverFailed, message: message)
        }
    }

    func setReceiverIcon(_ image: NSImage?) { receiverIcon.image = image }

    func refreshPresentation() { presentation.setActive(live && window?.isVisible == true) }

    /// The picture changed shape: keep the panel's area and corner, and resize in that shape from now on.
    func updateAspect(_ aspect: CGFloat) {
        guard let window, aspect.isFinite, aspect > 0, abs(aspect - aspectRatio) > 0.001 else { return }
        aspectRatio = aspect
        updateScreenLimits()
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let frame = AspectChange.frame(
            current: window.frame, aspectRatio: aspect, visibleFrame: visible,
            margin: Self.margin, minimumWidth: Self.minimumWidth)
        applyFrame(frame)
        presentation.rebase(aspect: aspect)
    }

    private func showOverlay(title: String, message: String, showsSettingsButton: Bool = false) {
        statusLabel.stringValue = title
        messageLabel.stringValue = message
        settingsButton.isHidden = !showsSettingsButton
        overlay.isHidden = false
    }

    @objc private func openLocalNetworkSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") else { return }
        NSWorkspace.shared.open(url)
    }

    private func placeAtDefaultCorner() {
        guard let window else { return }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(480, screen.width - 2 * Self.margin)
        let dropped = CGRect(x: screen.maxX - width, y: screen.minY, width: width, height: width / aspectRatio)
        let frame = PanelPlacement.snappedFrame(
            dropped: dropped,
            screens: [screen],
            aspectRatio: aspectRatio,
            margin: Self.margin,
            minimumWidth: Self.minimumWidth
        )
        window.setFrame(frame, display: true)
    }

    func windowDidMove(_ notification: Notification) {
        guard !updatingFrame else { return }
        presentation.reanchor()
        scheduleSnap()
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        snapTimer?.invalidate()
        presentation.reanchor()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        presentation.rebase(aspect: aspectRatio)
        scheduleSnap()
    }

    func windowWillClose(_ notification: Notification) {
        snapTimer?.invalidate()
        presentation.setActive(false)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateScreenLimits()
        guard !updatingFrame, NSApp.currentEvent?.type != .leftMouseDragged else { return }
        fitToScreen()
    }

    func fitToScreen() {
        guard let window, let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        updateScreenLimits()
        applyFrame(PresentationLayout.frame(width: window.frame.width, anchoredTo: window.frame, aspect: aspectRatio,
                                            in: screen, margin: Self.margin, minimumWidth: Self.minimumWidth))
        presentation.reanchor()
    }

    private func updateScreenLimits() {
        guard let window, let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let limit = SizeLayout.clampedSize(proposed: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 0),
                                          aspectRatio: aspectRatio, visibleFrame: screen, margin: Self.margin)
        let minWidth = min(Self.minimumWidth, limit.width)
        window.contentMinSize = NSSize(width: minWidth, height: minWidth / aspectRatio)
        window.contentMaxSize = limit
        window.contentAspectRatio = NSSize(width: aspectRatio, height: 1)
    }

    private func applyFrame(_ frame: CGRect) {
        guard let window, frame != window.frame else { return }
        updatingFrame = true
        defer { updatingFrame = false }
        window.setFrame(frame, display: true, animate: false)
    }

    private func scheduleSnap() {
        snapTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(applySnap), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        snapTimer = timer
    }

    @objc private func applySnap() {
        guard let window else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 || window.inLiveResize {
            scheduleSnap()
            return
        }
        let screens = NSScreen.screens.map(\.visibleFrame)
        let snapped = PanelSnapping.cornerSnappedFrame(
            frame: window.frame,
            screens: screens,
            aspectRatio: aspectRatio,
            margin: Self.margin,
            minimumWidth: Self.minimumWidth,
            threshold: Self.snapThreshold
        )
        applyFrame(snapped)
        presentation.reanchor()
    }
}
