/// Shared visual properties every annotation carries. `fillColor == .clear`
/// means stroke-only.
public struct AnnotationStyle: Codable, Sendable, Equatable {
    public var strokeColor: RGBAColor
    public var strokeWidth: Double
    public var fillColor: RGBAColor

    public init(strokeColor: RGBAColor = .red,
                strokeWidth: Double = 4,
                fillColor: RGBAColor = .clear) {
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.fillColor = fillColor
    }
}
