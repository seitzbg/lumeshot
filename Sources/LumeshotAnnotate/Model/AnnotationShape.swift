import CoreGraphics

/// The closed set of editor shapes. Box shapes carry their normalized rect;
/// line/arrow carry endpoints; freehand/highlighter carry point lists; step
/// carries its center and badge number. Coordinates are image-pixel space,
/// top-left origin, y-down (see plan Global Constraints). Text color and
/// highlighter color are taken from `style.strokeColor` at render time.
public enum AnnotationShape: Codable, Sendable, Equatable {
    case rectangle(rect: CGRect)
    case ellipse(rect: CGRect)
    case line(start: CGPoint, end: CGPoint)
    case arrow(start: CGPoint, end: CGPoint)
    case freehand(points: [CGPoint])
    // M3b:
    case crop(rect: CGRect)
    case text(rect: CGRect, string: String, fontSize: Double)
    case highlighter(points: [CGPoint])
    case blur(rect: CGRect, radius: Double)
    case pixelate(rect: CGRect, scale: Double)
    case step(center: CGPoint, number: Int)
}
