import Foundation

package struct PresentationActivity {
    package enum Focus { case neutral, local, sender }

    private struct Burst {
        let confirmation: Double
        let maxGap: Double
        var first: Double?
        var last = -Double.infinity

        mutating func record(at time: Double) {
            guard time > last else { return }
            if first == nil || time >= freshUntil { first = time }
            last = time
        }

        var confirmed: Bool { first.map { last - $0 >= confirmation } ?? false }
        var freshUntil: Double { last + maxGap }
    }

    private static let idleDelay = 2.4
    private static let minimumDwell = 1.25
    private static let senderHandoffDelay = 1.6
    private var local = Burst(confirmation: 0.20, maxGap: 0.58)
    private var sender = Burst(confirmation: 0.55, maxGap: 0.48)
    private var current = Focus.neutral
    private var changedAt = -Double.infinity

    package init() {}

    package mutating func recordLocal(at time: Double) {
        guard time > local.last else { return }
        local.record(at: time)
        // Require fresh sender evidence for any takeover without discarding its last activity.
        sender.first = nil
    }

    package mutating func recordSender(at time: Double) {
        // Ignore callbacks queued before the newest Mac input.
        guard time > local.last else { return }
        sender.record(at: time)
    }

    package mutating func focus(at time: Double) -> Focus {
        let handoffs = handoffTimes
        let next: Focus
        if let local = handoffs.local, time >= local, time < self.local.freshUntil {
            next = .local
        } else if let sender = handoffs.sender, time >= sender, time < self.sender.freshUntil {
            next = .sender
        } else if time >= idleAt {
            next = .neutral
        } else {
            next = current
        }
        if next != current {
            current = next
            changedAt = time
        }
        return current
    }

    package func nextUpdate(after time: Double) -> Double? {
        let handoffs = handoffTimes
        return [handoffs.local, handoffs.sender, current == .neutral ? nil : idleAt]
            .compactMap { $0 }.filter { $0 > time }.min()
    }

    private var idleAt: Double {
        // Activity from the other side only matters if it qualifies to take over.
        switch current {
        case .local: local.last + Self.idleDelay
        case .sender: sender.last + Self.idleDelay
        case .neutral: .infinity
        }
    }

    private var handoffTimes: (local: Double?, sender: Double?) {
        // Evidence must still be fresh when the dwell or handoff ends.
        let dwellUntil = current == .neutral ? -Double.infinity : changedAt + Self.minimumDwell
        let localAt = max(dwellUntil, local.last)
        let senderAt = max(dwellUntil, local.last + Self.senderHandoffDelay, sender.last)
        return (
            current != .local && local.confirmed && localAt < local.freshUntil ? localAt : nil,
            current != .sender && sender.confirmed && senderAt < sender.freshUntil ? senderAt : nil
        )
    }
}

/// Moving a zoomed panel changes its anchor, not its neutral width.
package struct PresentationBaseline {
    package let width: CGFloat
    package private(set) var anchor: CGRect

    package init(frame: CGRect) {
        width = frame.width
        anchor = frame
    }

    package mutating func moveAnchor(to frame: CGRect) { anchor = frame }
}

package struct PresentationSpring {
    package private(set) var value: CGFloat
    package private(set) var velocity: CGFloat = 0

    package init(value: CGFloat) { self.value = value }

    /// Closed-form critically damped spring; changing the target preserves position and velocity.
    package mutating func advance(toward target: CGFloat, by elapsed: Double) {
        guard elapsed > 0 else { return }
        let time = min(elapsed, 1)
        let frequency = 18.0
        let displacement = value - target
        let carry = velocity + frequency * displacement
        let decay = exp(-frequency * time)
        value = target + (displacement + carry * time) * decay
        velocity = (velocity - frequency * carry * time) * decay
    }
}

package enum PresentationLayout {
    package static func frame(width: CGFloat, anchoredTo base: CGRect, aspect: CGFloat,
                              in screen: CGRect, margin: CGFloat, minimumWidth: CGFloat) -> CGRect {
        let size = SizeLayout.clampedSize(
            proposed: CGSize(width: width, height: width / aspect), aspectRatio: aspect,
            visibleFrame: screen, margin: margin, minimumWidth: minimumWidth)
        let x = base.midX < screen.midX ? base.minX : base.maxX - size.width
        let y = base.midY < screen.midY ? base.minY : base.maxY - size.height
        return CGRect(x: min(max(x, screen.minX + margin), screen.maxX - margin - size.width),
                      y: min(max(y, screen.minY + margin), screen.maxY - margin - size.height),
                      width: size.width, height: size.height)
    }
}
