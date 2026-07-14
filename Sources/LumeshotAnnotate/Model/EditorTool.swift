/// The active editor tool. `.select` edits existing annotations; the rest draw
/// or place. M3b adds crop, text, highlighter, blur, pixelate and step.
public enum EditorTool: String, Codable, Sendable, CaseIterable {
    case select
    case rectangle
    case ellipse
    case line
    case arrow
    case freehand
    // M3b:
    case crop
    case text
    case highlighter
    case blur
    case pixelate
    case step
}
