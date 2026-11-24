import CoreGraphics
import Testing
import WindowLayout

@Suite struct SizeLayoutTests {
    @Test func oversizedWindowIsClampedToVisibleFrameKeepingAspectRatio() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = SizeLayout.clampedSize(
            proposed: CGSize(width: 3000, height: 1500),
            aspectRatio: 2,
            visibleFrame: visible,
            margin: 16
        )
        #expect(size == CGSize(width: 968, height: 484))
    }

    @Test func undersizedWindowIsRaisedToMinimumWidthKeepingAspectRatio() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = SizeLayout.clampedSize(
            proposed: CGSize(width: 50, height: 25),
            aspectRatio: 2,
            visibleFrame: visible,
            margin: 16,
            minimumWidth: 200
        )
        #expect(size == CGSize(width: 200, height: 100))
    }
}
