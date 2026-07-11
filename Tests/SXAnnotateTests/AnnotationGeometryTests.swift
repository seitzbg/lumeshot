import Testing
import CoreGraphics
@testable import SXAnnotate

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
}
