import CoreGraphics
import Testing
@testable import WindowLayout

@Suite struct PresentationTests {
    @Test func briefPausesOnEitherSideDoNotRestoreTheWindow() {
        var activity = PresentationActivity()
        activity.recordLocal(at: 1)
        activity.recordLocal(at: 1.25)
        #expect(activity.focus(at: 1.25) == .local)
        #expect(activity.focus(at: 2.5) == .local)
        activity.recordLocal(at: 2.6)
        #expect(activity.focus(at: 4.85) == .local)
        #expect(activity.focus(at: 5.01) == .neutral)

        activity.recordSender(at: 6)
        activity.recordSender(at: 6.20)
        activity.recordSender(at: 6.4)
        activity.recordSender(at: 6.6)
        #expect(activity.focus(at: 6.6) == .sender)
        #expect(activity.focus(at: 8.0) == .sender)
        #expect(activity.focus(at: 9.01) == .neutral)
    }

    @Test func fastAlternatingBurstsKeepTheWindowAtOneSize() {
        var activity = PresentationActivity()
        activity.recordLocal(at: 1)
        activity.recordLocal(at: 1.25)
        #expect(activity.focus(at: 1.25) == .local)
        for cycle in 0..<8 {
            let time = 1.55 + Double(cycle) * 1.1
            activity.recordSender(at: time)
            activity.recordSender(at: time + 0.2)
            activity.recordSender(at: time + 0.4)
            #expect(activity.focus(at: time + 0.4) == .local)
            activity.recordLocal(at: time + 0.7)
            activity.recordLocal(at: time + 0.95)
            #expect(activity.focus(at: time + 0.95) == .local)
        }
    }

    @Test func singleClicksAndIsolatedPictureChangesDoNotTakeOver() {
        var activity = PresentationActivity()
        activity.recordLocal(at: 1)
        #expect(activity.focus(at: 1.25) == .neutral)
        activity.recordSender(at: 1.8)
        #expect(activity.focus(at: 2.0) == .neutral)
        activity.recordSender(at: 2.8)
        #expect(activity.focus(at: 2.9) == .neutral)
    }

    @Test func aShortSenderFlurryDoesNotStartZooming() {
        var activity = PresentationActivity()
        for time in [1.0, 1.1, 1.2, 1.3, 1.4] { activity.recordSender(at: time) }
        #expect(activity.focus(at: 1.4) == .neutral)
        #expect(activity.nextUpdate(after: 1.4) == nil)
    }

    @Test func freshSustainedSenderTakesOverAfterMacHasActuallyPaused() {
        var activity = PresentationActivity()
        activity.recordLocal(at: 1)
        activity.recordLocal(at: 1.25)
        #expect(activity.focus(at: 1.25) == .local)
        for time in [2.10, 2.3, 2.5, 2.7] { activity.recordSender(at: time) }
        #expect(activity.focus(at: 2.7) == .local)
        #expect(activity.nextUpdate(after: 2.7) == 2.85)
        #expect(activity.focus(at: 2.86) == .sender)
    }

    @Test func aMacBurstCanTakeOverButNoImmediateReturnFollows() {
        var activity = PresentationActivity()
        for time in [1.0, 1.2, 1.4, 1.6] { activity.recordSender(at: time) }
        #expect(activity.focus(at: 1.6) == .sender)
        activity.recordLocal(at: 1.7)
        #expect(activity.focus(at: 1.7) == .sender)
        activity.recordLocal(at: 1.93)
        #expect(activity.focus(at: 1.93) == .sender)
        activity.recordLocal(at: 2.43)
        activity.recordLocal(at: 2.8)
        #expect(activity.focus(at: 2.86) == .local)
        for time in [3.0, 3.2, 3.4, 3.6] { activity.recordSender(at: time) }
        #expect(activity.focus(at: 3.6) == .local)
    }

    @Test func previousSenderActivityDoesNotReturnAfterLocalInput() {
        var activity = PresentationActivity()
        for time in [1.0, 1.2, 1.4, 1.6] { activity.recordSender(at: time) }
        #expect(activity.focus(at: 1.6) == .sender)
        activity.recordLocal(at: 2.8)
        activity.recordLocal(at: 3.05)
        #expect(activity.focus(at: 3.05) == .local)
        activity.recordSender(at: 3.01) // Delivered late, from before the newest Mac input.
        #expect(activity.focus(at: 4.7) == .local)
        #expect(activity.focus(at: 5.46) == .neutral)
    }

    @Test func isolatedSenderChangesDoNotKeepThePanelShrunkForever() {
        var activity = PresentationActivity()
        activity.recordLocal(at: 1)
        activity.recordLocal(at: 1.25)
        #expect(activity.focus(at: 1.25) == .local)
        activity.recordSender(at: 2.2)
        activity.recordSender(at: 3.5)
        let deadline = activity.nextUpdate(after: 3.5)
        #expect(abs((deadline ?? 0) - 3.65) < 0.001)
        #expect(activity.focus(at: 3.66) == .neutral)
    }

    @Test func movingAZoomedPanelDoesNotMakeItsEnlargedWidthTheNewBaseline() {
        let start = CGRect(x: 700, y: 16, width: 480, height: 270)
        let movedWhileZoomed = CGRect(x: 620, y: 104, width: 567, height: 319)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        var baseline = PresentationBaseline(frame: start)
        baseline.moveAnchor(to: movedWhileZoomed)
        let neutral = PresentationLayout.frame(width: baseline.width, anchoredTo: baseline.anchor, aspect: 16.0 / 9,
                                               in: screen, margin: 16, minimumWidth: 240)
        #expect(neutral.width == 480)
        #expect(neutral.maxX == movedWhileZoomed.maxX)
        #expect(neutral.minY == movedWhileZoomed.minY)
    }

    @Test func retargetingKeepsVelocityThenNaturallyReverses() {
        var spring = PresentationSpring(value: 480)
        spring.advance(toward: 560, by: 0.045)
        let interrupted = spring.value
        let moving = spring.velocity
        spring.advance(toward: 400, by: 0)
        #expect(spring.value == interrupted)
        #expect(spring.velocity == moving)
        spring.advance(toward: 400, by: 0.001)
        #expect(spring.value > interrupted)
        spring.advance(toward: 400, by: 0.08)
        #expect(spring.velocity < 0)
        spring.advance(toward: 400, by: 0.35)
        #expect(abs(spring.value - 400) < 1)
    }

    @Test func returnToNeutralEasesOutWithoutCrossingTheTarget() {
        var spring = PresentationSpring(value: 570)
        spring.advance(toward: 480, by: 0.16)
        #expect((484...515).contains(spring.value))
        for _ in 0..<20 {
            let previous = spring.value
            spring.advance(toward: 480, by: 0.016)
            #expect(spring.value >= 480)
            #expect(spring.value <= previous)
        }
        #expect(abs(spring.value - 480) < 1)
    }

    @Test func zoomRespectsCornerAndSmallOffsetPortraitScreen() {
        let screen = CGRect(x: -900, y: 140, width: 320, height: 620)
        let base = CGRect(x: -906, y: 156, width: 310, height: 550)
        let enlarged = PresentationLayout.frame(width: 400, anchoredTo: base,
            aspect: 9.0 / 16.0, in: screen, margin: 16, minimumWidth: 240)
        #expect(screen.insetBy(dx: 16, dy: 16).contains(enlarged))
        #expect(enlarged.maxX == base.maxX)
        #expect(enlarged.minY == base.minY)
        #expect(abs(enlarged.width / enlarged.height - 9.0 / 16.0) < 0.001)
    }

    @Test func minimumYieldsWhenScreenCannotFitIt() {
        let size = SizeLayout.clampedSize(proposed: CGSize(width: 360, height: 640),
            aspectRatio: 9.0 / 16.0, visibleFrame: CGRect(x: 0, y: 0, width: 320, height: 390),
            margin: 16, minimumWidth: 240)
        #expect(size.width > 0)
        #expect(size.height <= 358)
    }
}
