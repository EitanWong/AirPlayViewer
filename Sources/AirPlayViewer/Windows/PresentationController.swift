import AppKit
import QuartzCore
import WindowLayout

/// Resizes the panel, not the video. Only runs a display link while the spring is moving.
final class PresentationController: NSObject {
    weak var window: NSWindow?
    var applyFrame: ((CGRect) -> Void)?
    private(set) var enabled = false
    private var active = false
    private var amount: CGFloat = 0.18
    private var aspect: CGFloat = 16 / 9
    private var base: PresentationBaseline?
    private var activity = PresentationActivity()
    private var spring = PresentationSpring(value: 0)
    private var target: CGFloat = 0
    private var lastTick: CFTimeInterval?
    private var link: CADisplayLink?
    private var expiry: Timer?
    private var expiryDeadline: TimeInterval?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var globalKeyMonitor: Any?
    private var motionObserver: NSObjectProtocol?
    private var ownsPointer = false

    func configure(enabled: Bool, amount: CGFloat) {
        self.enabled = enabled
        self.amount = amount
        if !enabled { setActive(false) } else { update() }
    }

    func setActive(_ live: Bool) {
        let shouldRun = live && enabled
        guard active != shouldRun else { return }
        active = shouldRun
        activity = PresentationActivity()
        if active {
            rebase(aspect: aspect)
            let mask: NSEvent.EventTypeMask = [
                .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged,
                .otherMouseDragged, .scrollWheel, .keyDown, .magnify, .swipe
            ]
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask.union(.leftMouseUp)) { [weak self] event in
                // Never move the mirror out from under a drag or resize on its own window.
                guard let self else { return event }
                if event.type == .leftMouseUp, self.ownsPointer {
                    self.ownsPointer = false
                    self.update()
                } else if event.window === self.window {
                    if event.type == .leftMouseDown {
                        self.ownsPointer = true
                        self.stopLink()
                    }
                } else if event.type != .leftMouseUp {
                    self.localInput(event)
                }
                return event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask.subtracting(.keyDown)) { [weak self] event in
                self?.localInput(event)
            }
            // AppKit restricts global key events independently of pointer events.
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.localInput(event)
            }
            motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.update() }
        } else {
            removeObservers()
            ownsPointer = false
            scheduleUpdate(at: nil, now: CACurrentMediaTime())
            // Disabling or disconnecting restores the user's original size.
            if let base, window?.isVisible == true { updateTarget(width: base.width) }
            else { stopLink(); base = nil }
        }
    }

    /// Adopt a manual resize or a change of aspect as the new neutral frame.
    func rebase(aspect: CGFloat) {
        guard let window else { return }
        self.aspect = aspect
        activity = PresentationActivity()
        scheduleUpdate(at: nil, now: CACurrentMediaTime())
        base = PresentationBaseline(frame: window.frame)
        resetSpring(width: window.frame.width)
    }

    func reanchor() {
        guard let window else { return }
        base?.moveAnchor(to: window.frame)
        resetSpring(width: window.frame.width)
        update()
    }

    private func resetSpring(width: CGFloat) {
        stopLink()
        spring = PresentationSpring(value: width)
        target = width
    }

    func senderInput(at time: TimeInterval) {
        guard active else { return }
        activity.recordSender(at: time)
        update()
    }

    private func localInput(_ event: NSEvent) {
        guard active else { return }
        // Finger-up momentum is animation, not continued Mac interaction.
        if event.type == .scrollWheel, !event.momentumPhase.isEmpty { return }
        activity.recordLocal(at: CACurrentMediaTime())
        update()
    }

    private func update() {
        guard active, let base else { return }
        let time = CACurrentMediaTime()
        let scale: CGFloat
        switch activity.focus(at: time) {
        case .neutral: scale = 1
        case .local: scale = 1 - amount
        case .sender: scale = 1 + amount
        }
        updateTarget(width: base.width * scale)
        scheduleUpdate(at: activity.nextUpdate(after: time), now: time)
    }

    private func scheduleUpdate(at deadline: TimeInterval?, now: TimeInterval) {
        // An earlier wake can recheck an extended idle deadline; replace it only for a sooner handoff.
        if let deadline, let expiryDeadline, expiryDeadline <= deadline { return }
        expiry?.invalidate()
        expiry = nil
        expiryDeadline = nil
        guard let deadline else { return }
        let timer = Timer(timeInterval: max(0.001, deadline - now), repeats: false) { [weak self] _ in
            self?.expiry = nil
            self?.expiryDeadline = nil
            self?.update()
        }
        timer.tolerance = 0.02
        expiry = timer
        expiryDeadline = deadline
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateTarget(width: CGFloat) {
        // AppKit can consume mouse-up in its tracking loop; consult the current button state too.
        if NSEvent.pressedMouseButtons & 1 == 0 { ownsPointer = false }
        guard let window, window.isVisible, !window.inLiveResize, !ownsPointer,
              let base, let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let next = constrained(width: width, anchor: base.anchor, screen: screen)
        target = next.width
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopLink()
            spring = PresentationSpring(value: target)
            applyFrame?(next)
        } else if link == nil, abs(target - spring.value) >= 0.5 {
            let link = window.displayLink(target: self, selector: #selector(tick(_:)))
            lastTick = CACurrentMediaTime()
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let window, window.isVisible, !window.inLiveResize, let base,
              let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { stopLink(); return }
        let timestamp = link.targetTimestamp
        spring.advance(toward: target, by: timestamp - (lastTick ?? timestamp))
        lastTick = timestamp
        let settled = abs(spring.value - target) < 0.5 && abs(spring.velocity) < 12
        if settled {
            spring = PresentationSpring(value: target)
            stopLink()
        }
        let frame = constrained(width: spring.value, anchor: base.anchor, screen: screen)
        if window.frame != frame { applyFrame?(frame) }
    }

    private func constrained(width: CGFloat, anchor: CGRect, screen: CGRect) -> CGRect {
        PresentationLayout.frame(width: width, anchoredTo: anchor, aspect: aspect, in: screen,
                                 margin: PanelController.margin, minimumWidth: PanelController.minimumWidth)
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        lastTick = nil
    }

    private func removeObservers() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
        localMonitor = nil
        globalMonitor = nil
        globalKeyMonitor = nil
        motionObserver = nil
    }
}
