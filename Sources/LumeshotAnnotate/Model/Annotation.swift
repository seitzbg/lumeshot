import Foundation

/// One item in the non-destructive document. List order is z-order (later = on top).
public struct Annotation: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var shape: AnnotationShape
    public var style: AnnotationStyle

    public init(id: UUID = UUID(), shape: AnnotationShape, style: AnnotationStyle) {
        self.id = id
        self.shape = shape
        self.style = style
    }
}
