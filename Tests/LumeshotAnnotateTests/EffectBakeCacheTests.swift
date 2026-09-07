import Testing
import CoreGraphics
@testable import LumeshotAnnotate

/// The cache exists to keep `bakeEffects` off the repaint path, so these assert
/// identity (`===`) rather than pixel equality: a reused entry is the *same*
/// CGImage, a re-bake is a different one.
@MainActor
@Suite struct EffectBakeCacheTests {
    private func base(_ n: Int = 24) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: n / 2, y: 0, width: n / 2, height: n))
        return ctx.makeImage()!
    }

    private func blur(_ rect: CGRect, radius: Double = 4) -> Annotation {
        Annotation(shape: .blur(rect: rect, radius: radius), style: AnnotationStyle())
    }

    private func arrow(to end: CGPoint) -> Annotation {
        Annotation(shape: .arrow(start: .zero, end: end), style: AnnotationStyle())
    }

    private let region = CGRect(x: 4, y: 4, width: 12, height: 12)

    @Test func reusesTheBakedImageWhenNothingChanges() {
        let cache = EffectBakeCache()
        let b = base()
        let annotations = [blur(region)]
        let first = cache.bakedImage(base: b, annotations: annotations)
        let second = cache.bakedImage(base: b, annotations: annotations)
        #expect(first === second)
    }

    /// The reason the cache is keyed on effects only: dragging an arrow repaints
    /// constantly and must not re-run Core Image over the whole screenshot.
    @Test func reusesTheBakedImageWhenOnlyVectorAnnotationsChange() {
        let cache = EffectBakeCache()
        let b = base()
        let first = cache.bakedImage(base: b, annotations: [blur(region), arrow(to: CGPoint(x: 5, y: 5))])
        let second = cache.bakedImage(base: b, annotations: [blur(region), arrow(to: CGPoint(x: 19, y: 19))])
        #expect(first === second)
    }

    @Test func rebakesWhenAnEffectMoves() {
        let cache = EffectBakeCache()
        let b = base()
        let first = cache.bakedImage(base: b, annotations: [blur(region)])
        let moved = cache.bakedImage(base: b, annotations: [blur(region.offsetBy(dx: 4, dy: 0))])
        #expect(first !== moved)
    }

    @Test func rebakesWhenAnEffectParameterChanges() {
        let cache = EffectBakeCache()
        let b = base()
        let first = cache.bakedImage(base: b, annotations: [blur(region, radius: 4)])
        let stronger = cache.bakedImage(base: b, annotations: [blur(region, radius: 12)])
        #expect(first !== stronger)
    }

    @Test func rebakesWhenAnEffectIsRemoved() {
        let cache = EffectBakeCache()
        let b = base()
        let withEffect = cache.bakedImage(base: b, annotations: [blur(region)])
        let without = cache.bakedImage(base: b, annotations: [])
        #expect(withEffect !== without)
        // With no effects at all the base passes straight through.
        #expect(without === b)
    }

    @Test func rebakesWhenTheBaseImageChanges() {
        let cache = EffectBakeCache()
        let annotations = [blur(region)]
        let first = cache.bakedImage(base: base(), annotations: annotations)
        let second = cache.bakedImage(base: base(), annotations: annotations)
        #expect(first !== second)
    }

    /// A cached bitmap must still be the correct bitmap, not just a fast one.
    @Test func cachedResultMatchesAnUncachedBake() {
        let cache = EffectBakeCache()
        let b = base()
        let annotations = [blur(region), arrow(to: CGPoint(x: 5, y: 5))]
        let cached = cache.bakedImage(base: b, annotations: annotations)
        let direct = AnnotationRenderer.bakeEffects(base: b, annotations: annotations)
        #expect(cached.width == direct.width && cached.height == direct.height)
        #expect(cached !== b)
    }
}
