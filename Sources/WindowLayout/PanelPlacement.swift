import CoreGraphics

public enum PanelPlacement {
    /// Final frame for a panel dropped at `dropped`: uses the screen nearest its center, clamps the size, snaps to the nearest corner.
    public static func snappedFrame(
        dropped: CGRect,
        screens: [CGRect],
        aspectRatio: CGFloat,
        margin: CGFloat,
        minimumWidth: CGFloat
    ) -> CGRect {
        let center = CGPoint(x: dropped.midX, y: dropped.midY)
        guard let screen = screens.min(by: {
            distanceSquared(from: center, to: $0) < distanceSquared(from: center, to: $1)
        }) else { return dropped }
        let size = SizeLayout.clampedSize(
            proposed: dropped.size,
            aspectRatio: aspectRatio,
            visibleFrame: screen,
            margin: margin,
            minimumWidth: minimumWidth
        )
        let origin = SnapLayout.snappedOrigin(
            windowSize: size,
            proposedOrigin: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
            visibleFrame: screen,
            margin: margin
        )
        return CGRect(origin: origin, size: size)
    }

    private static func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
