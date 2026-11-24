import CoreGraphics

public enum SnapLayout {
    /// Returns the window origin snapped to the nearest corner of `visibleFrame`, inset by `margin`.
    public static func snappedOrigin(
        windowSize: CGSize,
        proposedOrigin: CGPoint,
        visibleFrame: CGRect,
        margin: CGFloat
    ) -> CGPoint {
        let centerX = proposedOrigin.x + windowSize.width / 2
        let centerY = proposedOrigin.y + windowSize.height / 2
        let x = centerX < visibleFrame.midX
            ? visibleFrame.minX + margin
            : visibleFrame.maxX - windowSize.width - margin
        let y = centerY < visibleFrame.midY
            ? visibleFrame.minY + margin
            : visibleFrame.maxY - windowSize.height - margin
        return CGPoint(x: x, y: y)
    }
}
