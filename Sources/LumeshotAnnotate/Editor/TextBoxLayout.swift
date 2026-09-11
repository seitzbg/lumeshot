import Foundation
import CoreGraphics
import CoreText

/// Lays out text the way the renderer does, so the editor can keep a text box
/// tall enough for its content.
///
/// The committed renderer frames CoreText inside the annotation's rectangle and
/// clips to it (`AnnotationRenderer.drawText`). A box sized for a small font no
/// longer fits a larger one, so the glyphs simply do not draw — the export
/// "succeeds" with no text. Measuring with the same font and wrapping width lets
/// a font-size change grow the box to fit.
enum TextBoxLayout {
    /// The height needed to lay `string` out at `fontSize` within `width`, at
    /// least one line. Uses the same font family as `AnnotationRenderer`.
    static func fittingHeight(string: String, fontSize: Double, width: CGFloat) -> CGFloat {
        let font = CTFontCreateWithName(AnnotationDefaults.textFontName as CFString, CGFloat(fontSize), nil)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        // An empty box still reserves a line, so an emptied text annotation does
        // not collapse to zero height mid-edit.
        let measured = string.isEmpty ? " " : string
        let attr = NSAttributedString(string: measured, attributes: [fontKey: font])
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let constraint = CGSize(width: max(width, 1), height: .greatestFiniteMagnitude)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)
        return ceil(size.height)
    }
}
