import CoreGraphics

public enum CaptureGeometry {
    /// Rect from two drag points, any drag direction.
    public static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// View-point selection (top-left origin, same space as the frozen image)
    /// -> pixel crop rect, clamped to image bounds.
    public static func pixelCropRect(selection: CGRect, scale: CGFloat,
                                     imageWidth: Int, imageHeight: Int) -> CGRect {
        let scaled = CGRect(x: selection.origin.x * scale, y: selection.origin.y * scale,
                            width: selection.width * scale, height: selection.height * scale)
        let bounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        return scaled.intersection(bounds).integral
    }
}
