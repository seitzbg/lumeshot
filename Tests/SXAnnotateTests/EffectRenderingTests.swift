import Testing
import CoreGraphics
@testable import SXAnnotate

@Suite struct EffectRenderingTests {
    /// 40×40: left half black, right half white (a sharp vertical edge at x=20).
    private func edgeBase(_ n: Int = 40) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: n / 2, y: 0, width: n / 2, height: n))
        return ctx.makeImage()!
    }

    /// (r,g,b,a) at top-left pixel (x,y).
    private func sample(_ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let row = h - 1 - y
        let i = (row * w + x) * 4
        return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]), Int(buf[i + 3]))
    }

    private func channelDelta(_ a: (Int, Int, Int, Int), _ b: (Int, Int, Int, Int)) -> Int {
        abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
    }

    @Test func bakeEffectsReturnsBaseWhenNoEffects() {
        let b = edgeBase()
        let vector = Annotation(id: .init(),
                                shape: .rectangle(rect: CGRect(x: 1, y: 1, width: 5, height: 5)),
                                style: AnnotationStyle())
        #expect(AnnotationRenderer.bakeEffects(base: b, annotations: [vector]) === b)
        #expect(AnnotationRenderer.bakeEffects(base: b, annotations: []) === b)
    }

    @Test func blurChangesPixelsInsideRectAndLeavesOutsideUnchanged() {
        let b = edgeBase()
        let blur = Annotation(id: .init(),
                              shape: .blur(rect: CGRect(x: 10, y: 10, width: 20, height: 20), radius: 8),
                              style: AnnotationStyle())
        let out = AnnotationRenderer.bakeEffects(base: b, annotations: [blur])
        #expect(out !== b)                                             // a new image was produced
        #expect(channelDelta(sample(b, 20, 20), sample(out, 20, 20)) > 20)   // edge inside rect blurred
        #expect(sample(out, 2, 20) == sample(b, 2, 20))               // far-left outside rect: base black
        #expect(sample(out, 37, 20) == sample(b, 37, 20))            // far-right outside rect: base white
    }

    @Test func pixelateChangesPixelsInsideRect() {
        let b = edgeBase()
        let px = Annotation(id: .init(),
                            shape: .pixelate(rect: CGRect(x: 10, y: 10, width: 20, height: 20), scale: 12),
                            style: AnnotationStyle())
        let out = AnnotationRenderer.bakeEffects(base: b, annotations: [px])
        // CIPixellate nearest-samples each block at its center rather than box-averaging;
        // with scale 12 and center (0,0), the block spanning x∈[12,24) samples at x=18
        // (still base-black), so x=20..23 (base-white) flips to black while x=13 does not.
        #expect(channelDelta(sample(b, 22, 20), sample(out, 22, 20)) > 20)  // block's nearest sample flips this pixel
        #expect(sample(out, 2, 20) == sample(b, 2, 20))               // outside rect: base unchanged
    }

    @Test func bakeEffectsDoesNotMutateTheBase() {
        let b = edgeBase()
        let before = sample(b, 13, 20)   // black
        let blur = Annotation(id: .init(),
                              shape: .blur(rect: CGRect(x: 10, y: 10, width: 20, height: 20), radius: 8),
                              style: AnnotationStyle())
        _ = AnnotationRenderer.bakeEffects(base: b, annotations: [blur])
        #expect(sample(b, 13, 20) == before)   // the original base pixel is untouched
    }

    @Test func flattenCropsOutputToTheCropRect() throws {
        let b = edgeBase()
        let crop = Annotation(id: .init(),
                              shape: .crop(rect: CGRect(x: 5, y: 8, width: 20, height: 15)),
                              style: AnnotationStyle())
        let out = try #require(AnnotationRenderer.flatten(base: b, annotations: [crop]))
        #expect(out.width == 20)
        #expect(out.height == 15)
        #expect(b.width == 40 && b.height == 40)   // base object dimensions unchanged
    }
}
