import CoreGraphics

/// The closed set of v1 vector shapes. Box shapes carry their normalized rect;
/// line/arrow carry endpoints; freehand carries its point list. Coordinates are
/// image-pixel space, top-left origin, y-down (see plan Global Constraints).
public enum AnnotationShape: Codable, Sendable, Equatable {
    case rectangle(rect: CGRect)
    case ellipse(rect: CGRect)
    case line(start: CGPoint, end: CGPoint)
    case arrow(start: CGPoint, end: CGPoint)
    case freehand(points: [CGPoint])
}
