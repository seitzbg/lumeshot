import Testing
import CoreGraphics
@testable import LumeshotAnnotate

@Suite struct AnnotationGeometryTests {
    private func ann(_ shape: AnnotationShape) -> Annotation {
        Annotation(id: .init(), shape: shape, style: AnnotationStyle())
    }

    @Test func rectSpanningNormalizesReversedCorners() {
        let r = CGRect(spanning: CGPoint(x: 30, y: 40), CGPoint(x: 10, y: 5))
        #expect(r == CGRect(x: 10, y: 5, width: 20, height: 35))
    }

    @Test func boundsOfBoxIsItsRect() {
        let rect = CGRect(x: 4, y: 6, width: 20, height: 10)
        #expect(ann(.rectangle(rect: rect)).bounds == rect)
        #expect(ann(.ellipse(rect: rect)).bounds == rect)
    }

    @Test func boundsOfLineSpansEndpoints() {
        let b = ann(.line(start: CGPoint(x: 10, y: 2), end: CGPoint(x: 2, y: 9))).bounds
        #expect(b == CGRect(x: 2, y: 2, width: 8, height: 7))
    }

    @Test func boundsOfFreehandSpansAllPoints() {
        let b = ann(.freehand(points: [CGPoint(x: 5, y: 5), CGPoint(x: 1, y: 9), CGPoint(x: 8, y: 3)])).bounds
        #expect(b == CGRect(x: 1, y: 3, width: 7, height: 6))
    }

    @Test func rectangleHitTestUsesInflatedBounds() {
        let a = ann(.rectangle(rect: CGRect(x: 10, y: 10, width: 40, height: 30)))
        #expect(a.hitTest(CGPoint(x: 30, y: 25), tolerance: 8))   // inside
        #expect(a.hitTest(CGPoint(x: 6, y: 25), tolerance: 8))    // within tolerance outside
        #expect(!a.hitTest(CGPoint(x: 0, y: 0), tolerance: 8))    // far away
    }

    @Test func ellipseHitTestRejectsCorner() {
        let a = ann(.ellipse(rect: CGRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(a.hitTest(CGPoint(x: 50, y: 50), tolerance: 5))   // center
        #expect(!a.hitTest(CGPoint(x: 2, y: 2), tolerance: 5))    // corner is outside the ellipse
    }

    @Test func lineHitTestUsesSegmentDistance() {
        let a = ann(.line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0)))
        #expect(a.hitTest(CGPoint(x: 50, y: 3), tolerance: 6))    // near the segment
        #expect(!a.hitTest(CGPoint(x: 50, y: 20), tolerance: 6))  // far from the segment
        #expect(!a.hitTest(CGPoint(x: 150, y: 0), tolerance: 6))  // beyond the endpoint
    }

    @Test func freehandHitTestNearAnySegment() {
        let a = ann(.freehand(points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]))
        #expect(a.hitTest(CGPoint(x: 10, y: 5), tolerance: 4))    // near second segment
        #expect(!a.hitTest(CGPoint(x: 0, y: 10), tolerance: 4))   // interior, not near any segment
    }

    @Test func boundsOfCropTextAndEffectsAreTheirRects() {
        let r = CGRect(x: 4, y: 6, width: 20, height: 10)
        #expect(ann(.crop(rect: r)).bounds == r)
        #expect(ann(.text(rect: r, string: "x", fontSize: 20)).bounds == r)
        #expect(ann(.blur(rect: r, radius: 8)).bounds == r)
        #expect(ann(.pixelate(rect: r, scale: 12)).bounds == r)
    }

    @Test func boundsOfHighlighterSpansAllPoints() {
        let b = ann(.highlighter(points: [CGPoint(x: 5, y: 5), CGPoint(x: 1, y: 9), CGPoint(x: 8, y: 3)])).bounds
        #expect(b == CGRect(x: 1, y: 3, width: 7, height: 6))
    }

    @Test func boundsOfStepIsRadiusSquareAroundCenter() {
        let b = ann(.step(center: CGPoint(x: 30, y: 40), number: 2)).bounds
        let r = AnnotationDefaults.stepRadius
        #expect(b == CGRect(x: 30 - r, y: 40 - r, width: r * 2, height: r * 2))
    }

    @Test func cropAndEffectRectsHitTestLikeRectangles() {
        let r = CGRect(x: 10, y: 10, width: 40, height: 30)
        for shape in [AnnotationShape.crop(rect: r),
                      .blur(rect: r, radius: 8),
                      .pixelate(rect: r, scale: 12),
                      .text(rect: r, string: "x", fontSize: 20)] {
            let a = ann(shape)
            #expect(a.hitTest(CGPoint(x: 30, y: 25), tolerance: 8))   // inside
            #expect(a.hitTest(CGPoint(x: 6, y: 25), tolerance: 8))    // within tolerance outside
            #expect(!a.hitTest(CGPoint(x: 0, y: 0), tolerance: 8))    // far away
        }
    }

    @Test func highlighterHitTestUsesWideStrokeBand() {
        let a = ann(.highlighter(points: [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0)]))
        // Even with tolerance 1, the 12pt min stroke width gives a ~6px hit band.
        #expect(a.hitTest(CGPoint(x: 20, y: 5), tolerance: 1))
        #expect(!a.hitTest(CGPoint(x: 20, y: 40), tolerance: 1))
    }

    @Test func stepHitTestUsesRadiusPlusTolerance() {
        let a = ann(.step(center: CGPoint(x: 30, y: 30), number: 1))
        #expect(a.hitTest(CGPoint(x: 36, y: 30), tolerance: 2))   // distance 6 <= 14 + 2
        #expect(!a.hitTest(CGPoint(x: 60, y: 30), tolerance: 2))  // distance 30 > 16
    }

    @Test func zeroLengthLineBoundsAndHit() {
        let p = CGPoint(x: 20, y: 20)
        let a = ann(.line(start: p, end: p))
        #expect(a.bounds == CGRect(x: 20, y: 20, width: 0, height: 0))
        #expect(a.hitTest(CGPoint(x: 22, y: 20), tolerance: 4))     // within tolerance of the point
        #expect(!a.hitTest(CGPoint(x: 30, y: 20), tolerance: 4))    // too far
    }

    @Test func singlePointFreehandBoundsAndHit() {
        let a = ann(.freehand(points: [CGPoint(x: 8, y: 8)]))
        #expect(a.bounds == CGRect(x: 8, y: 8, width: 0, height: 0))
        #expect(a.hitTest(CGPoint(x: 9, y: 8), tolerance: 3))       // near the lone point
        #expect(!a.hitTest(CGPoint(x: 20, y: 20), tolerance: 3))
    }

    @Test func emptyFreehandHasZeroBoundsAndNeverHits() {
        let a = ann(.freehand(points: []))
        #expect(a.bounds == .zero)
        #expect(!a.hitTest(CGPoint(x: 0, y: 0), tolerance: 100))
    }
}
