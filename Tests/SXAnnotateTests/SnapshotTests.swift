import Testing
import CoreGraphics
import Foundation
import ImageIO
@testable import SXAnnotate

@Suite struct SnapshotTests {
    /// A representative document exercising every vector shape.
    static func compositeImage() -> CGImage {
        let w = 200, h = 150
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let base = ctx.makeImage()!
        let red = RGBAColor.red
        let blueFill = RGBAColor(r: 0.2, g: 0.4, b: 0.9, a: 0.5)
        let annotations: [Annotation] = [
            Annotation(id: .init(), shape: .rectangle(rect: CGRect(x: 10, y: 10, width: 60, height: 40)),
                       style: AnnotationStyle(strokeColor: red, strokeWidth: 4, fillColor: blueFill)),
            Annotation(id: .init(), shape: .ellipse(rect: CGRect(x: 90, y: 15, width: 50, height: 30)),
                       style: AnnotationStyle(strokeColor: red, strokeWidth: 4)),
            Annotation(id: .init(), shape: .line(start: CGPoint(x: 10, y: 90), end: CGPoint(x: 90, y: 120)),
                       style: AnnotationStyle(strokeColor: red, strokeWidth: 5)),
            Annotation(id: .init(), shape: .arrow(start: CGPoint(x: 110, y: 120), end: CGPoint(x: 180, y: 80)),
                       style: AnnotationStyle(strokeColor: red, strokeWidth: 5)),
            Annotation(id: .init(), shape: .freehand(points: [
                CGPoint(x: 150, y: 20), CGPoint(x: 165, y: 40), CGPoint(x: 150, y: 55), CGPoint(x: 175, y: 60)]),
                       style: AnnotationStyle(strokeColor: red, strokeWidth: 3)),
        ]
        return AnnotationRenderer.flatten(base: base, annotations: annotations)!
    }

    private func load(_ data: Data) -> CGImage {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCreateImageAtIndex(src, 0, nil)!
    }

    /// Mean absolute per-channel difference (0…255) between two same-size images.
    private func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
        precondition(a.width == b.width && a.height == b.height)
        let w = a.width, h = a.height
        func bytes(_ img: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buf
        }
        let ba = bytes(a), bb = bytes(b)
        var total = 0.0
        for i in 0..<ba.count { total += Double(abs(Int(ba[i]) - Int(bb[i]))) }
        return total / Double(ba.count)
    }

    @Test func compositeMatchesGolden() throws {
        let rendered = Self.compositeImage()
        let goldenURL = try #require(Bundle.module.url(forResource: "composite", withExtension: "png", subdirectory: "Fixtures"))
        let goldenData = try Data(contentsOf: goldenURL)
        let golden = load(goldenData)
        // Generous tolerance: absorbs cross-SDK anti-aliasing, catches real regressions.
        #expect(meanDifference(rendered, golden) < 4.0)
    }
}
