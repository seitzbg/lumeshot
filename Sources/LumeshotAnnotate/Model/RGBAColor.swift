import CoreGraphics

/// An sRGB color with channels in 0…1. Codable/Sendable so it lives in the
/// document model; `cgColor` bridges to CoreGraphics at the render boundary.
public struct RGBAColor: Codable, Sendable, Equatable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// ShareX's default annotation stroke, #ef4444.
    public static let red = RGBAColor(r: 0.937, g: 0.267, b: 0.267, a: 1)
    public static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)

    public var cgColor: CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    public var isClear: Bool { a == 0 }
}
