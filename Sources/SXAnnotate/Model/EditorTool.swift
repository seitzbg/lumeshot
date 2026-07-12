/// The active editor tool. `.select` edits existing annotations; the rest draw.
/// M3b extends this enum (crop, text, highlight, blur, pixelate, step).
public enum EditorTool: String, Codable, Sendable, CaseIterable {
    case select
    case rectangle
    case ellipse
    case line
    case arrow
    case freehand
}
