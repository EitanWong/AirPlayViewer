import CoreGraphics

public enum PanelSnapping {
    /// Snaps a dropped panel to a corner only when its edges are within `threshold` of that screen's edges.
    public static func cornerSnappedFrame(
        frame: CGRect,
        screens: [CGRect],
        aspectRatio: CGFloat,
        margin: CGFloat,
        minimumWidth: CGFloat,
        threshold: CGFloat
    ) -> CGRect {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = screens.min(by: {
            distanceSquared(from: center, to: $0) < distanceSquared(from: center, to: $1)
        }) else { return frame }
        let size = SizeLayout.clampedSize(
            proposed: frame.size,
            aspectRatio: aspectRatio,
            visibleFrame: screen,
            margin: margin,
            minimumWidth: minimumWidth
        )
        let nearLeft = frame.minX - screen.minX <= threshold
        let nearRight = screen.maxX - frame.maxX <= threshold
        let nearBottom = frame.minY - screen.minY <= threshold
        let nearTop = screen.maxY - frame.maxY <= threshold
        guard (nearLeft || nearRight), (nearBottom || nearTop) else { return frame }
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
