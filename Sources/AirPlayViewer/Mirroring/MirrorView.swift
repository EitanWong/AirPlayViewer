import AppKit
import CoreVideo
import QuartzCore

/// Shows decoded pictures. Each picture's IOSurface becomes the layer's contents, so nothing is copied.
final class MirrorView: NSView {
    private let pictureLayer = CALayer()
    /// Kept so the decoder does not reuse the surface while it is on screen.
    private var shown: CVPixelBuffer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // A layer-hosting view: AppKit leaves the contents of these layers alone.
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        pictureLayer.frame = root.bounds
        pictureLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        pictureLayer.contentsGravity = .resizeAspect
        pictureLayer.isOpaque = true
        root.addSublayer(pictureLayer)
        layer = root
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L10n.windowTitle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { true }

    /// Puts a decoded picture on screen. Main thread.
    func show(_ picture: CVPixelBuffer) {
        guard let surface = CVPixelBufferGetIOSurface(picture)?.takeUnretainedValue() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pictureLayer.contents = surface
        CATransaction.commit()
        shown = picture
    }

    /// Removes the picture. Main thread.
    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pictureLayer.contents = nil
        CATransaction.commit()
        shown = nil
    }
}
