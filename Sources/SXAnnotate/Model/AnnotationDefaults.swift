import CoreGraphics

/// Shared default constants for M3b annotation kinds (text/highlighter/effects/step),
/// so the model (creation) and renderer (drawing) agree on one set of numbers.
public enum AnnotationDefaults {
    public static let textFontSize: Double = 24
    public static let highlighterAlpha: Double = 0.4
    public static let highlighterMinWidth: CGFloat = 12
    public static let stepRadius: CGFloat = 14
    public static let stepFontSize: CGFloat = 15
    public static let blurRadius: Double = 8
    public static let pixelScale: Double = 12
}
