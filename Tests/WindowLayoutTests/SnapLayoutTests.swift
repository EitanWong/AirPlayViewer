import CoreGraphics
import Testing
import WindowLayout

@Suite struct SnapLayoutTests {
    @Test func windowDroppedNearBottomRightSnapsToBottomRightCorner() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let origin = SnapLayout.snappedOrigin(
            windowSize: CGSize(width: 320, height: 180),
            proposedOrigin: CGPoint(x: 650, y: 40),
            visibleFrame: visible,
            margin: 16
        )
        #expect(origin == CGPoint(x: 664, y: 16))
    }

    @Test func windowDroppedNearTopLeftSnapsToTopLeftCorner() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let origin = SnapLayout.snappedOrigin(
            windowSize: CGSize(width: 320, height: 180),
            proposedOrigin: CGPoint(x: 30, y: 560),
            visibleFrame: visible,
            margin: 16
        )
        #expect(origin == CGPoint(x: 16, y: 604))
    }

    @Test func windowDroppedNearTopRightOnOffsetDisplaySnapsToTopRightCorner() {
        let visible = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let origin = SnapLayout.snappedOrigin(
            windowSize: CGSize(width: 320, height: 180),
            proposedOrigin: CGPoint(x: 700, y: 600),
            visibleFrame: visible,
            margin: 16
        )
        #expect(origin == CGPoint(x: 764, y: 654))
    }

    @Test func windowDroppedNearBottomLeftOnOffsetDisplaySnapsToBottomLeftCorner() {
        let visible = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let origin = SnapLayout.snappedOrigin(
            windowSize: CGSize(width: 320, height: 180),
            proposedOrigin: CGPoint(x: 120, y: 60),
            visibleFrame: visible,
            margin: 16
        )
        #expect(origin == CGPoint(x: 116, y: 66))
    }
}
