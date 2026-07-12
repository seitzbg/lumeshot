import Testing
import CoreGraphics
@testable import SXAnnotate

@Suite struct CanvasGeometryTests {
    @Test func fitsWideImageWithVerticalLetterbox() {
        // 100x50 image in a 200x200 view → scale 2, displayed 200x100, centered vertically.
        let g = CanvasGeometry(imageSize: CGSize(width: 100, height: 50),
                               viewSize: CGSize(width: 200, height: 200))
        #expect(g.scale == 2)
        #expect(g.imageRectInView == CGRect(x: 0, y: 50, width: 200, height: 100))
    }

    @Test func imageTopLeftMapsToDisplayedTopLeftInView() {
        let g = CanvasGeometry(imageSize: CGSize(width: 100, height: 50),
                               viewSize: CGSize(width: 200, height: 200))
        // Image (0,0) top-left → top of the displayed rect (view y is up, so the top is y = 150).
        let v = g.imageToView(CGPoint(x: 0, y: 0))
        #expect(v.x == 0)
        #expect(v.y == 150)
        // Image bottom-right (100,50) → bottom-right of the displayed rect (view y = 50).
        let v2 = g.imageToView(CGPoint(x: 100, y: 50))
        #expect(v2.x == 200)
        #expect(v2.y == 50)
    }

    @Test func viewToImageInvertsImageToView() {
        let g = CanvasGeometry(imageSize: CGSize(width: 120, height: 80),
                               viewSize: CGSize(width: 300, height: 300))
        for p in [CGPoint(x: 10, y: 10), CGPoint(x: 119, y: 1), CGPoint(x: 60, y: 79)] {
            let back = g.viewToImage(g.imageToView(p))
            #expect(abs(back.x - p.x) < 0.001)
            #expect(abs(back.y - p.y) < 0.001)
        }
    }

    @Test func transformMatchesImageToView() {
        let g = CanvasGeometry(imageSize: CGSize(width: 100, height: 50),
                               viewSize: CGSize(width: 200, height: 200))
        let p = CGPoint(x: 40, y: 25)
        let viaTransform = p.applying(g.imageToViewTransform)
        let viaFunc = g.imageToView(p)
        #expect(abs(viaTransform.x - viaFunc.x) < 0.001)
        #expect(abs(viaTransform.y - viaFunc.y) < 0.001)
    }

    @Test func zeroImageSizeUsesUnitScale() {
        let g = CanvasGeometry(imageSize: .zero, viewSize: CGSize(width: 200, height: 100))
        #expect(g.scale == 1)
        // The displayed rect collapses to a centered zero-size rect.
        #expect(g.imageRectInView == CGRect(x: 100, y: 50, width: 0, height: 0))
    }

    @Test func viewToImageWithZeroScaleReturnsZero() {
        // A non-empty image in a zero-size view forces scale 0; the guard returns .zero
        // instead of dividing by zero.
        let g = CanvasGeometry(imageSize: CGSize(width: 10, height: 10), viewSize: .zero)
        #expect(g.scale == 0)
        #expect(g.viewToImage(CGPoint(x: 5, y: 5)) == .zero)
    }
}
