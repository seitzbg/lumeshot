import AppKit
import SwiftUI
import SXAnnotate

/// Custom AppKit canvas: renders the document with `AnnotationRenderer` and
/// forwards pointer events (converted to image coordinates) to `EditorModel`.
@MainActor
final class EditorCanvasNSView: NSView {
    let model: EditorModel

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

        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(model.baseImage, in: geo.imageRectInView)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.concatenate(geo.imageToViewTransform)
        AnnotationRenderer.drawAnnotations(model.displayAnnotations, in: ctx)
        ctx.restoreGState()

        if let selected = model.selectedAnnotation {
            drawSelection(selected, geo: geo, in: ctx)
        }
    }

    private func drawSelection(_ annotation: Annotation, geo: CanvasGeometry, in ctx: CGContext) {
        // Dashed bounding outline.
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

        // Solid grips.
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

    // MARK: Mouse

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        geometry.viewToImage(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
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
        nsView.needsDisplay = true
    }
}
