import CoreGraphics
import Testing
import WindowLayout

@Suite struct PanelSnappingTests {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func frameDroppedNearBottomRightEdgeSnapsToCorner() {
        let frame = CGRect(x: 650, y: 40, width: 320, height: 160)
        let snapped = PanelSnapping.cornerSnappedFrame(
            frame: frame,
            screens: [screen],
            aspectRatio: 2,
            margin: 16,
            minimumWidth: 200,
            threshold: 60
        )
        #expect(snapped == CGRect(x: 664, y: 16, width: 320, height: 160))
    }

    @Test func frameDroppedInTheMiddleStaysPut() {
        let frame = CGRect(x: 400, y: 300, width: 320, height: 160)
        let snapped = PanelSnapping.cornerSnappedFrame(
            frame: frame,
            screens: [screen],
            aspectRatio: 2,
            margin: 16,
            minimumWidth: 200,
            threshold: 60
        )
        #expect(snapped == frame)
    }

    @Test func frameNearOneEdgeOnlyStaysPut() {
        let frame = CGRect(x: 20, y: 300, width: 320, height: 160)
        let snapped = PanelSnapping.cornerSnappedFrame(
            frame: frame,
            screens: [screen],
            aspectRatio: 2,
            margin: 16,
            minimumWidth: 200,
            threshold: 60
        )
        #expect(snapped == frame)
    }
}
