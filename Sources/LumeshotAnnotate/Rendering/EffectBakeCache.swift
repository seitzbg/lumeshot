import CoreGraphics

/// Remembers the most recent `bakeEffects` result so repainting does not re-run
/// Core Image on every frame.
///
/// The canvas repaints on every mouse-moved event, and a drag produces many of
/// them; baking a full-resolution screenshot through CIGaussianBlur that often is
/// the editor's main source of lag. The cache key is the **effect annotations
/// alone**, so dragging an arrow, typing in a text box or moving the selection
/// reuses the cached bitmap — only a blur/pixelate edit, or a different base
/// image, forces a re-bake.
///
/// Main-actor isolated because it exists to serve `NSView.draw(_:)`; it holds one
/// entry, so it costs one baked image and never grows.
@MainActor
public final class EffectBakeCache {
    private var cachedEffects: [Annotation] = []
    private var cachedBase: CGImage?
    private var cachedResult: CGImage?

    public init() {}

    /// The base with its blur/pixelate regions baked in, reusing the previous
    /// result when nothing that affects it has changed.
    public func bakedImage(base: CGImage, annotations: [Annotation]) -> CGImage {
        let effects = annotations.filter(\.shape.isEffect)
        if let cachedResult, let cachedBase, cachedBase === base, cachedEffects == effects {
            return cachedResult
        }
        let result = AnnotationRenderer.bakeEffects(base: base, annotations: effects)
        cachedEffects = effects
        cachedBase = base
        cachedResult = result
        return result
    }
}
