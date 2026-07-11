import CoreGraphics

/// Maps between image-pixel space (top-left origin, y-down) and a centered,
/// aspect-fit rectangle inside a non-flipped AppKit view (bottom-left, y-up).
public struct CanvasGeometry: Sendable {
    public let imageSize: CGSize
    public let viewSize: CGSize
    public let scale: CGFloat
    public let imageRectInView: CGRect

    public init(imageSize: CGSize, viewSize: CGSize) {
        self.imageSize = imageSize
        self.viewSize = viewSize
        let s: CGFloat
        if imageSize.width > 0 && imageSize.height > 0 {
            s = Swift.min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        } else {
            s = 1
        }
        self.scale = s
        let dispW = imageSize.width * s, dispH = imageSize.height * s
        self.imageRectInView = CGRect(x: (viewSize.width - dispW) / 2,
                                      y: (viewSize.height - dispH) / 2,
                                      width: dispW, height: dispH)
    }

    /// image(top-left, y-down) → view(bottom-left, y-up).
    public var imageToViewTransform: CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                          tx: imageRectInView.minX,
                          ty: imageRectInView.minY + imageRectInView.height)
    }

    public func imageToView(_ p: CGPoint) -> CGPoint {
        p.applying(imageToViewTransform)
    }

    public func viewToImage(_ p: CGPoint) -> CGPoint {
        guard scale != 0 else { return .zero }
        return CGPoint(x: (p.x - imageRectInView.minX) / scale,
                       y: (imageRectInView.minY + imageRectInView.height - p.y) / scale)
    }
}
