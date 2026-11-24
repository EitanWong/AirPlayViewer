import CoreGraphics
import Testing
import WindowLayout

@Suite struct AspectChangeTests {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func changed(_ current: CGRect, to aspect: CGFloat, minimumWidth: CGFloat = 100) -> CGRect {
        AspectChange.frame(
            current: current, aspectRatio: aspect, visibleFrame: screen, margin: 16, minimumWidth: minimumWidth)
    }

    @Test func panelInTheBottomRightCornerKeepsItsAreaAndThatCorner() {
        // 400 x 200 landscape becomes 200 x 400 portrait; the right and bottom edges stay where they were.
        let frame = changed(CGRect(x: 584, y: 16, width: 400, height: 200), to: 0.5)
        #expect(frame == CGRect(x: 784, y: 16, width: 200, height: 400))
    }

    @Test func panelInTheTopLeftCornerKeepsThatCorner() {
        let frame = changed(CGRect(x: 16, y: 584, width: 400, height: 200), to: 0.5)
        #expect(frame == CGRect(x: 16, y: 384, width: 200, height: 400))
    }

    @Test func portraitPanelTurningLandscapeGrowsSideways() {
        let frame = changed(CGRect(x: 784, y: 16, width: 200, height: 400), to: 2)
        #expect(frame == CGRect(x: 584, y: 16, width: 400, height: 200))
    }

    @Test func sameShapeLeavesThePanelAlone() {
        let current = CGRect(x: 300, y: 250, width: 400, height: 200)
        #expect(changed(current, to: 2) == current)
    }

    @Test func resultIsNoLargerThanTheScreenAllows() {
        // Area 405 000 at 1:2 would be 450 x 900; the screen leaves 768 of height.
        let frame = changed(CGRect(x: 84, y: 16, width: 900, height: 450), to: 0.5)
        #expect(frame == CGRect(x: 600, y: 16, width: 384, height: 768))
    }

    @Test func resultIsNoNarrowerThanTheMinimumWidth() {
        let frame = changed(CGRect(x: 744, y: 16, width: 240, height: 120), to: 0.5, minimumWidth: 240)
        #expect(frame == CGRect(x: 744, y: 16, width: 240, height: 480))
    }

    @Test func panelThatWouldLeaveTheScreenIsMovedBackInside() {
        // Its centre is in the lower half, so it grows upward from y = 240; 240 + 600 passes the top margin at 784.
        let frame = changed(CGRect(x: 100, y: 240, width: 600, height: 300), to: 0.5)
        #expect(frame == CGRect(x: 100, y: 184, width: 300, height: 600))
    }
}
