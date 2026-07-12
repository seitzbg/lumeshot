import Testing
import CoreGraphics
@testable import SXAnnotate

@Suite struct AnnotationRendererTests {
    /// A solid white base image of the given size.
    private func whiteBase(_ w: Int, _ h: Int) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// Reads back pixels using top-left (image) coordinates.
    private struct Sampler {
        let w: Int, h: Int
        var buf: [UInt8]
        init(_ image: CGImage) {
            w = image.width; h = image.height
            buf = [UInt8](repeating: 0, count: w * h * 4)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        /// (r,g,b,a) at top-left pixel (x,y). The backing buffer is bottom-left, so flip the row.
        func rgba(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let row = h - 1 - y
            let i = (row * w + x) * 4
            return (buf[i], buf[i + 1], buf[i + 2], buf[i + 3])
        }
    }

    @Test func flattenPreservesBaseWhereUnannotated() throws {
        let out = AnnotationRenderer.flatten(base: whiteBase(60, 60), annotations: [])
        let s = Sampler(try #require(out))
        let (r, g, b, _) = s.rgba(30, 30)
        #expect(r > 240 && g > 240 && b > 240)
    }

    @Test func filledRectanglePaintsItsInterior() throws {
        let fill = RGBAColor(r: 0, g: 0, b: 1, a: 1)  // blue
        let a = Annotation(id: .init(),
                           shape: .rectangle(rect: CGRect(x: 10, y: 10, width: 40, height: 40)),
                           style: AnnotationStyle(strokeColor: .clear, strokeWidth: 0, fillColor: fill))
        let out = try #require(AnnotationRenderer.flatten(base: whiteBase(60, 60), annotations: [a]))
        let s = Sampler(out)
        let (r, g, b, _) = s.rgba(30, 30)     // center of the rect
        #expect(b > 200 && r < 60 && g < 60)  // blue interior
        let (r2, _, _, _) = s.rgba(2, 2)      // outside the rect, still white base
        #expect(r2 > 240)
    }

    @Test func strokedLinePaintsAlongItsPath() throws {
        let stroke = RGBAColor(r: 1, g: 0, b: 0, a: 1)  // red
        let a = Annotation(id: .init(),
                           shape: .line(start: CGPoint(x: 5, y: 30), end: CGPoint(x: 55, y: 30)),
                           style: AnnotationStyle(strokeColor: stroke, strokeWidth: 6, fillColor: .clear))
        let out = try #require(AnnotationRenderer.flatten(base: whiteBase(60, 60), annotations: [a]))
        let s = Sampler(out)
        let (r, g, b, _) = s.rgba(30, 30)   // on the line
        #expect(r > 200 && g < 60 && b < 60)
        let (_, g2, _, _) = s.rgba(30, 5)   // well above the line, still white
        #expect(g2 > 240)
    }

    @Test func highlighterMultipliesOverTheBase() throws {
        let yellow = RGBAColor(r: 1, g: 1, b: 0, a: 1)
        let a = Annotation(id: .init(),
                           shape: .highlighter(points: [CGPoint(x: 10, y: 30), CGPoint(x: 50, y: 30)]),
                           style: AnnotationStyle(strokeColor: yellow, strokeWidth: 4))
        let out = try #require(AnnotationRenderer.flatten(base: whiteBase(60, 60), annotations: [a]))
        let s = Sampler(out)
        let (r, g, b, _) = s.rgba(30, 30)   // on the stroke
        #expect(b < 220)                    // multiply with yellow (b=0) darkens blue
        #expect(r > 200 && g > 200)         // red/green preserved
        let (_, _, b2, _) = s.rgba(30, 5)   // above the stroke, untouched white base
        #expect(b2 > 240)
    }

    @Test func stepBadgePaintsAFilledDisc() throws {
        let a = Annotation(id: .init(),
                           shape: .step(center: CGPoint(x: 30, y: 30), number: 1),
                           style: AnnotationStyle(strokeColor: .red, strokeWidth: 4))
        let out = try #require(AnnotationRenderer.flatten(base: whiteBase(60, 60), annotations: [a]))
        let s = Sampler(out)
        let (r, g, b, _) = s.rgba(22, 30)   // ~8px left of center: inside disc, off the glyph
        #expect(r > 180 && g < 120 && b < 120)   // red fill
        let (r2, g2, b2, _) = s.rgba(30, 5) // far outside the disc, white base
        #expect(r2 > 240 && g2 > 240 && b2 > 240)
    }

    @Test func textContributesInkWithinItsBox() throws {
        let a = Annotation(id: .init(),
                           shape: .text(rect: CGRect(x: 5, y: 5, width: 50, height: 40), string: "HI", fontSize: 28),
                           style: AnnotationStyle(strokeColor: .red, strokeWidth: 4))
        let out = try #require(AnnotationRenderer.flatten(base: whiteBase(60, 60), annotations: [a]))
        let s = Sampler(out)
        var inked = 0
        for y in 5..<45 { for x in 5..<55 {
            let (r, g, b, _) = s.rgba(x, y)
            if r < 230 || g < 230 || b < 230 { inked += 1 }
        } }
        #expect(inked > 0)                       // glyphs marked some pixels
        let (r2, g2, b2, _) = s.rgba(58, 58)     // far corner, outside the box
        #expect(r2 > 240 && g2 > 240 && b2 > 240)
    }
}
