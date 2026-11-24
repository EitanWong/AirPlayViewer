import CoreGraphics

public enum AspectChange {
    /// Frame for a panel whose picture changed shape. The panel keeps its area and stays against the
    /// screen corner it is nearest to, then is fitted inside `visibleFrame` minus `margin`.
    public static func frame(
        current: CGRect,
        aspectRatio: CGFloat,
        visibleFrame: CGRect,
        margin: CGFloat,
        minimumWidth: CGFloat
    ) -> CGRect {
        guard aspectRatio > 0, current.width > 0, current.height > 0,
              abs(current.width / current.height - aspectRatio) >= 0.001 else { return current }
        let width = (current.width * current.height * aspectRatio).squareRoot()
        let size = SizeLayout.clampedSize(
            proposed: CGSize(width: width, height: width / aspectRatio),
            aspectRatio: aspectRatio,
            visibleFrame: visibleFrame,
            margin: margin,
            minimumWidth: minimumWidth)
        // Keep the edges that face the nearest corner; the panel grows or shrinks toward the middle of the screen.
        var x = current.midX < visibleFrame.midX ? current.minX : current.maxX - size.width
        var y = current.midY < visibleFrame.midY ? current.minY : current.maxY - size.height
        x = min(max(x, visibleFrame.minX + margin), visibleFrame.maxX - margin - size.width)
        y = min(max(y, visibleFrame.minY + margin), visibleFrame.maxY - margin - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
