import Foundation
import CoreGraphics
import CoreText
import CoreImage

public enum AnnotationRenderer {
    // CIContext is thread-safe (per Apple); nonisolated(unsafe) satisfies Swift 6
    // strict concurrency without allocating a fresh context per call.
    nonisolated(unsafe) private static let ciContext = CIContext()

    /// Draws every annotation in image-pixel coordinates using the context's
    /// current CTM. The caller establishes the coordinate mapping (identity+flip
    /// for export, aspect-fit for the on-screen view).
    public static func drawAnnotations(_ annotations: [Annotation], in ctx: CGContext) {
        for annotation in annotations {
            draw(annotation, in: ctx)
        }
    }

    /// Composites blur/pixelate regions into the base via Core Image and returns a
    /// new CGImage. The base is never mutated. Effects composite BENEATH vector
    /// annotations (they bake into the image; vectors draw on top afterward).
    /// Rects are annotation space (top-left, y-down); converted to CI's bottom-left
    /// space here. Returns `base` unchanged when there are no effect annotations.
    public static func bakeEffects(base: CGImage, annotations: [Annotation]) -> CGImage {
        let effects = annotations.filter {
            if case .blur = $0.shape { return true }
            if case .pixelate = $0.shape { return true }
            return false
        }
        guard !effects.isEmpty else { return base }
        let h = CGFloat(base.height)
        let baseCI = CIImage(cgImage: base)
        var acc = baseCI
        for ann in effects {
            let rect: CGRect
            let filtered: CIImage
            switch ann.shape {
            case .blur(let r, let radius):
                rect = r.standardized
                filtered = baseCI.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                    .cropped(to: baseCI.extent)
            case .pixelate(let r, let scale):
                rect = r.standardized
                filtered = baseCI
                    .applyingFilter("CIPixellate",
                                    parameters: [kCIInputScaleKey: scale, kCIInputCenterKey: CIVector(x: 0, y: 0)])
            default:
                continue
            }
            // top-left rect → CI bottom-left crop region
            let ciRect = CGRect(x: rect.minX, y: h - rect.maxY, width: rect.width, height: rect.height)
                .intersection(baseCI.extent)
            guard !ciRect.isNull, !ciRect.isEmpty else { continue }
            acc = filtered.cropped(to: ciRect).composited(over: acc)
        }
        return ciContext.createCGImage(acc, from: baseCI.extent) ?? base
    }

    /// Composites `base` + `annotations` at native resolution: bakes blur/pixelate
    /// effects into the bitmap, draws base + vector/text/highlighter/step on top,
    /// then crops the output to the single `.crop` rect if one is present. Returns
    /// nil only if a bitmap context cannot be created.
    public static func flatten(base: CGImage, annotations: [Annotation]) -> CGImage? {
        let baked = bakeEffects(base: base, annotations: annotations)
        let w = baked.width, h = baked.height
        guard w > 0, h > 0,
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Baked bitmap drawn right-side up in the native bottom-left context.
        ctx.draw(baked, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Flip to top-left, y-down so annotation coordinates land correctly.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        drawAnnotations(annotations, in: ctx)     // vector+text+highlighter+step (skips crop/blur/pixelate)
        guard let full = ctx.makeImage() else { return nil }

        // Crop the output to the (single) crop rect, if any.
        if let crop = annotations.last(where: { if case .crop = $0.shape { return true }; return false }),
           case .crop(let r) = crop.shape {
            let px = r.standardized.intersection(CGRect(x: 0, y: 0, width: w, height: h))
            if !px.isNull, !px.isEmpty, let cropped = full.cropping(to: px) { return cropped }
        }
        return full
    }

    private static func draw(_ annotation: Annotation, in ctx: CGContext) {
        let style = annotation.style
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(CGFloat(style.strokeWidth))

        switch annotation.shape {
        case .rectangle(let rect):
            fillThenStroke(rect: rect.standardized, isEllipse: false, style: style, ctx: ctx)
        case .ellipse(let rect):
            fillThenStroke(rect: rect.standardized, isEllipse: true, style: style, ctx: ctx)
        case .line(let start, let end):
            strokePath(style: style, ctx: ctx) { $0.move(to: start); $0.addLine(to: end) }
        case .arrow(let start, let end):
            drawArrow(from: start, to: end, style: style, ctx: ctx)
        case .freehand(let points):
            guard points.count > 1 else { break }
            strokePath(style: style, ctx: ctx) {
                $0.move(to: points[0])
                for p in points.dropFirst() { $0.addLine(to: p) }
            }
        case .text(let rect, let string, let fontSize):
            drawText(rect, string: string, fontSize: fontSize, style: style, in: ctx)
        case .highlighter(let points):
            drawHighlighter(points, style: style, in: ctx)
        case .step(let center, let number):
            drawStep(center, number: number, style: style, in: ctx)
        case .crop, .blur, .pixelate:
            break   // crop = view-only chrome; blur/pixelate are baked by bakeEffects (Task 5)
        }
        ctx.restoreGState()
    }

    private static func fillThenStroke(rect: CGRect, isEllipse: Bool,
                                       style: AnnotationStyle, ctx: CGContext) {
        let path = CGMutablePath()
        if isEllipse { path.addEllipse(in: rect) } else { path.addRect(rect) }
        if !style.fillColor.isClear {
            ctx.addPath(path)
            ctx.setFillColor(style.fillColor.cgColor)
            ctx.fillPath()
        }
        if !style.strokeColor.isClear && style.strokeWidth > 0 {
            ctx.addPath(path)
            ctx.setStrokeColor(style.strokeColor.cgColor)
            ctx.strokePath()
        }
    }

    private static func strokePath(style: AnnotationStyle, ctx: CGContext,
                                   build: (CGMutablePath) -> Void) {
        guard !style.strokeColor.isClear, style.strokeWidth > 0 else { return }
        let path = CGMutablePath()
        build(path)
        ctx.addPath(path)
        ctx.setStrokeColor(style.strokeColor.cgColor)
        ctx.strokePath()
    }

    /// A straight shaft plus a filled classic arrowhead sized from the stroke width.
    private static func drawArrow(from start: CGPoint, to end: CGPoint,
                                  style: AnnotationStyle, ctx: CGContext) {
        guard !style.strokeColor.isClear, style.strokeWidth > 0 else { return }
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }
        ctx.setStrokeColor(style.strokeColor.cgColor)
        ctx.setFillColor(style.strokeColor.cgColor)
        let ux = dx / length, uy = dy / length                 // unit direction
        let headLength = Swift.min(Swift.max(12, CGFloat(style.strokeWidth) * 3), length)
        let headHalfWidth = Swift.max(7, CGFloat(style.strokeWidth) * 1.8)
        // Shaft stops at the base of the head so it doesn't poke through the tip.
        let baseX = end.x - ux * headLength, baseY = end.y - uy * headLength
        let shaft = CGMutablePath()
        shaft.move(to: start)
        shaft.addLine(to: CGPoint(x: baseX, y: baseY))
        ctx.addPath(shaft)
        ctx.strokePath()
        // Filled triangle: tip at end, two wings perpendicular to the direction.
        let px = -uy, py = ux                                   // perpendicular unit
        let head = CGMutablePath()
        head.move(to: end)
        head.addLine(to: CGPoint(x: baseX + px * headHalfWidth, y: baseY + py * headHalfWidth))
        head.addLine(to: CGPoint(x: baseX - px * headHalfWidth, y: baseY - py * headHalfWidth))
        head.closeSubpath()
        ctx.addPath(head)
        ctx.fillPath()
    }

    // TEXT
    private static func drawText(_ rect: CGRect, string: String, fontSize: Double,
                                 style: AnnotationStyle, in ctx: CGContext) {
        guard !string.isEmpty else { return }
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, CGFloat(fontSize), nil)
        // CoreText attribute keys (AppKit-free — LumeshotAnnotate must not import AppKit).
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let attr = NSAttributedString(string: string,
            attributes: [fontKey: font, colorKey: style.strokeColor.cgColor])
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(rect: CGRect(origin: .zero, size: rect.standardized.size), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        ctx.saveGState()
        ctx.translateBy(x: rect.standardized.minX, y: rect.standardized.minY + rect.standardized.height)
        ctx.scaleBy(x: 1, y: -1)      // counter the y-down CTM so CoreText draws upright
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    // HIGHLIGHTER
    private static func drawHighlighter(_ points: [CGPoint], style: AnnotationStyle, in ctx: CGContext) {
        guard points.count > 1 else { return }
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setLineWidth(max(CGFloat(style.strokeWidth), AnnotationDefaults.highlighterMinWidth))
        var c = style.strokeColor; c.a = AnnotationDefaults.highlighterAlpha
        ctx.setStrokeColor(c.cgColor)
        ctx.move(to: points[0]); for p in points.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // STEP BADGE
    private static func drawStep(_ center: CGPoint, number: Int, style: AnnotationStyle, in ctx: CGContext) {
        let radius = AnnotationDefaults.stepRadius
        let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius*2, height: radius*2)
        ctx.saveGState()
        ctx.setFillColor(style.strokeColor.cgColor)
        ctx.fillEllipse(in: circle)
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, AnnotationDefaults.stepFontSize, nil)
        // CoreText attribute keys (AppKit-free — LumeshotAnnotate must not import AppKit).
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(number)",
            attributes: [fontKey: font, colorKey: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)]))
        let b = CTLineGetImageBounds(line, ctx)
        ctx.translateBy(x: center.x - b.width/2 - b.minX, y: center.y + b.height/2 + b.minY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
