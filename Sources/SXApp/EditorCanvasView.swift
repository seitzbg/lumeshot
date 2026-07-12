import AppKit
import SwiftUI
import SXAnnotate

/// Custom AppKit canvas: renders the document (base + baked blur/pixelate effects +
/// vector/text/highlighter/step annotations + crop chrome), hosts an in-canvas
/// `NSTextField` for text editing, and forwards pointer events (converted to image
/// coordinates) to `EditorModel`.
///
/// EXPLICIT `@MainActor`: every AppKit view type in this project is annotated
/// `@MainActor` so the CI toolchain (macos-15 / Xcode-16.4 / Swift-6.0) type-checks the
/// same isolation the dev SDK infers implicitly (the M1/M3a lesson).
@MainActor
final class EditorCanvasNSView: NSView, NSTextFieldDelegate {
    let model: EditorModel
    private var textField: NSTextField?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }

    private var geometry: CanvasGeometry {
        CanvasGeometry(imageSize: CGSize(width: model.baseImage.width, height: model.baseImage.height),
                       viewSize: bounds.size)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let geo = geometry

        // Effect preview: composite blur/pixelate regions into the base via Core Image
        // so they show live. PERF CAVEAT: bakeEffects runs on every repaint (a drag =
        // many repaints); caching the baked image by annotation-signature is deferred.
        let baked = AnnotationRenderer.bakeEffects(base: model.baseImage,
                                                   annotations: model.displayAnnotations)
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(baked, in: geo.imageRectInView)
        ctx.restoreGState()

        // Vector + text + highlighter + step on top (drawAnnotations skips crop/blur/
        // pixelate). The text being edited is shown by the live NSTextField instead.
        let vectors = model.displayAnnotations.filter { $0.id != model.editingTextID }
        ctx.saveGState()
        ctx.concatenate(geo.imageToViewTransform)
        AnnotationRenderer.drawAnnotations(vectors, in: ctx)
        ctx.restoreGState()

        // Crop chrome: dim everything outside the crop rect. View-only — never exported.
        drawCropChrome(geo: geo, in: ctx)

        if let selected = model.selectedAnnotation {
            drawSelection(selected, geo: geo, in: ctx)
        }
    }

    private func drawCropChrome(geo: CanvasGeometry, in ctx: CGContext) {
        guard let crop = model.displayAnnotations.last(where: {
            if case .crop = $0.shape { return true }; return false
        }), case .crop(let r) = crop.shape else { return }
        let s = r.standardized
        let inner = CGRect(spanning: geo.imageToView(CGPoint(x: s.minX, y: s.minY)),
                           geo.imageToView(CGPoint(x: s.maxX, y: s.maxY)))
            .intersection(geo.imageRectInView)
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        let ring = CGMutablePath()
        ring.addRect(geo.imageRectInView)
        ring.addRect(inner)
        ctx.addPath(ring)
        ctx.fillPath(using: .evenOdd)          // fills the region OUTSIDE the crop rect
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(inner)
        ctx.restoreGState()
    }

    private func drawSelection(_ annotation: Annotation, geo: CanvasGeometry, in ctx: CGContext) {
        let b = annotation.bounds
        let corners = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                       CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
            .map { geo.imageToView($0) }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.addLines(between: corners + [corners[0]])
        ctx.strokePath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        for handle in annotation.handles() {
            let c = geo.imageToView(handle.point)
            let r = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
            ctx.fillEllipse(in: r)
            ctx.strokeEllipse(in: r)
        }
        ctx.restoreGState()
    }

    // MARK: In-canvas text editing

    /// Adds/positions/removes the overlay `NSTextField` to match `model.editingTextID`.
    /// Called from the representable's `updateNSView`, so any published change re-syncs it.
    func syncTextEditing() {
        guard let id = model.editingTextID else {
            teardownTextField()
            return
        }
        let field: NSTextField
        if let existing = textField {
            field = existing
        } else {
            field = makeTextField()
            textField = field
            addSubview(field)
            NotificationCenter.default.addObserver(
                self, selector: #selector(textDidChange(_:)),
                name: NSControl.textDidChangeNotification, object: field)
        }
        positionTextField(field, forAnnotationID: id)
        if field.currentEditor() == nil {
            window?.makeFirstResponder(field)   // focus once; don't steal the caret on every sync
        }
    }

    private func makeTextField() -> NSTextField {
        let field = NSTextField(frame: .zero)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.target = self
        field.action = #selector(commitTextEditing)   // Return commits
        field.delegate = self                         // catches Tab / click-away blur too
        return field
    }

    private func positionTextField(_ field: NSTextField, forAnnotationID id: Annotation.ID) {
        guard let ann = model.displayAnnotations.first(where: { $0.id == id }),
              case .text(let rect, let string, let fontSize) = ann.shape else { return }
        let geo = geometry
        let s = rect.standardized
        let frame = CGRect(spanning: geo.imageToView(CGPoint(x: s.minX, y: s.minY)),
                           geo.imageToView(CGPoint(x: s.maxX, y: s.maxY)))
        field.frame = frame.insetBy(dx: -2, dy: -2)
        field.font = .systemFont(ofSize: CGFloat(fontSize) * geo.scale)
        field.textColor = NSColor(srgbRed: model.strokeColor.r, green: model.strokeColor.g,
                                  blue: model.strokeColor.b, alpha: model.strokeColor.a)
        if field.stringValue != string { field.stringValue = string }
    }

    private func teardownTextField() {
        guard let field = textField else { return }
        NotificationCenter.default.removeObserver(self, name: NSControl.textDidChangeNotification,
                                                  object: field)
        field.removeFromSuperview()
        textField = nil
    }

    @objc private func textDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField, field === textField else { return }
        model.updateEditingText(field.stringValue)
        needsDisplay = true
    }

    @objc private func commitTextEditing() {
        model.endTextEditing()
        needsDisplay = true
    }

    /// Fires on ANY end-of-editing — Return, Tab/Backtab, and click-away blur (losing
    /// first responder) — unlike `field.action`, which (per `NSTextField(frame:)`
    /// defaulting `sendsActionOnEndEditing` to false) only fires on Return. Without this,
    /// clicking a SwiftUI toolbar control never calls `endTextEditing()`, leaving the
    /// overlay parked and Undo/Redo permanently disabled. Guarded against the redundant
    /// call `commitTextEditing()` already made for the Return case in the same runloop
    /// tick; `model.endTextEditing()` is itself idempotent either way.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard model.editingTextID != nil else { return }
        model.endTextEditing()
        needsDisplay = true
    }

    // MARK: Mouse

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        geometry.viewToImage(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking the canvas commits any in-progress text before the next gesture; the
        // model then routes the click (text → beginTextEditing, step → place badge, etc.).
        if model.editingTextID != nil { model.endTextEditing() }
        model.pointerDown(at: imagePoint(event)); needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        model.pointerDragged(to: imagePoint(event)); needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        model.pointerUp(at: imagePoint(event)); needsDisplay = true
    }
}

/// SwiftUI bridge for the AppKit canvas.
struct EditorCanvasView: NSViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeNSView(context: Context) -> EditorCanvasNSView {
        EditorCanvasNSView(model: model)
    }

    func updateNSView(_ nsView: EditorCanvasNSView, context: Context) {
        nsView.syncTextEditing()
        nsView.needsDisplay = true
    }
}
