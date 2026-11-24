import CoreGraphics
import Testing
import WindowLayout

@Suite struct PanelPlacementTests {
    @Test func windowDroppedOnSecondScreenSnapsToThatScreensNearestCorner() {
        let first = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let second = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let frame = PanelPlacement.snappedFrame(
            dropped: CGRect(x: 1500, y: 60, width: 320, height: 160),
            screens: [first, second],
            aspectRatio: 2,
            margin: 16,
            minimumWidth: 200
        )
        #expect(frame == CGRect(x: 1664, y: 16, width: 320, height: 160))
    }

    @Test func windowDroppedOutsideEveryScreenSnapsToNearestScreensCorner() {
        let first = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let second = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let frame = PanelPlacement.snappedFrame(
            dropped: CGRect(x: 2050, y: 600, width: 320, height: 160),
            screens: [first, second],
            aspectRatio: 2,
            margin: 16,
            minimumWidth: 200
        )
        #expect(frame == CGRect(x: 1664, y: 624, width: 320, height: 160))
    }
}
