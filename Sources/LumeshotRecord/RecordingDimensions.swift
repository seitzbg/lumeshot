import CoreGraphics

/// Output pixel dimensions + optional crop region for an SCStreamConfiguration.
/// Video encoders require EVEN width/height; all factories round down to even.
public struct RecordingDimensions: Equatable, Sendable {
    public let width: Int          // output pixels
    public let height: Int         // output pixels
    public let sourceRect: CGRect? // points, display-local top-left; nil = whole filter

    public init(width: Int, height: Int, sourceRect: CGRect?) {
        self.width = width
        self.height = height
        self.sourceRect = sourceRect
    }

    static func even(_ v: Int) -> Int { max(2, v - (v % 2)) }

    /// Whole display: capture at native pixel resolution, no crop.
    public static func display(pointWidth: CGFloat, pointHeight: CGFloat, scale: CGFloat) -> RecordingDimensions {
        RecordingDimensions(width: even(Int((pointWidth * scale).rounded())),
                            height: even(Int((pointHeight * scale).rounded())),
                            sourceRect: nil)
    }

    /// Region within a display: sourceRect in display-local points; output = region * scale, rounded even.
    public static func region(rectInPoints: CGRect, scale: CGFloat) -> RecordingDimensions {
        RecordingDimensions(width: even(Int((rectInPoints.width * scale).rounded())),
                            height: even(Int((rectInPoints.height * scale).rounded())),
                            sourceRect: rectInPoints)
    }

    /// Whole window: output = window size * scale, no crop (window filter already scopes content).
    public static func window(pointWidth: CGFloat, pointHeight: CGFloat, scale: CGFloat) -> RecordingDimensions {
        RecordingDimensions(width: even(Int((pointWidth * scale).rounded())),
                            height: even(Int((pointHeight * scale).rounded())),
                            sourceRect: nil)
    }
}
