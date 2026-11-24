import CoreGraphics

public enum SizeLayout {
    /// Fits `proposed` inside `visibleFrame` minus `margin` on every side, keeping `aspectRatio` (width / height).
    public static func clampedSize(
        proposed: CGSize,
        aspectRatio: CGFloat,
        visibleFrame: CGRect,
        margin: CGFloat,
        minimumWidth: CGFloat = 0
    ) -> CGSize {
        let availableWidth = max(0, visibleFrame.width - 2 * margin)
        let availableHeight = max(0, visibleFrame.height - 2 * margin)
        let width = min(max(minimumWidth, proposed.width), availableWidth, availableHeight * aspectRatio)
        return CGSize(width: width, height: width / aspectRatio)
    }
}
