import CoreGraphics
import Testing
@testable import SXCapture

@Suite struct CaptureGeometryTests {
    @Test func normalizesDragInAnyDirection() {
        let r = CaptureGeometry.normalizedRect(from: CGPoint(x: 100, y: 80),
                                               to: CGPoint(x: 20, y: 200))
        #expect(r == CGRect(x: 20, y: 80, width: 80, height: 120))
    }

    @Test func scalesSelectionToPixelsAndClamps() {
        // 2x display, image 200x100 px; selection 10,10 50x30 pt -> 20,20 100x60 px
        let r = CaptureGeometry.pixelCropRect(selection: CGRect(x: 10, y: 10, width: 50, height: 30),
                                              scale: 2, imageWidth: 200, imageHeight: 100)
        #expect(r == CGRect(x: 20, y: 20, width: 100, height: 60))
        // Selection hanging off the edge clamps to image bounds.
        let clamped = CaptureGeometry.pixelCropRect(selection: CGRect(x: 90, y: 40, width: 50, height: 30),
                                                    scale: 2, imageWidth: 200, imageHeight: 100)
        #expect(clamped == CGRect(x: 180, y: 80, width: 20, height: 20))
    }

    @Test func zeroSizeSelectionYieldsZeroRect() {
        let r = CaptureGeometry.pixelCropRect(selection: .zero, scale: 2,
                                              imageWidth: 200, imageHeight: 100)
        #expect(r.isEmpty)
    }

    @Test func flipsCGGlobalRectToAppKitCoordinates() {
        let r = CaptureGeometry.appKitRect(fromCGGlobal: CGRect(x: 100, y: 50, width: 200, height: 150),
                                           primaryHeight: 1000)
        #expect(r == CGRect(x: 100, y: 800, width: 200, height: 150))
    }

    @Test func flipsRectTouchingTheTop() {
        let r = CaptureGeometry.appKitRect(fromCGGlobal: CGRect(x: 0, y: 0, width: 300, height: 120),
                                           primaryHeight: 1000)
        #expect(r == CGRect(x: 0, y: 880, width: 300, height: 120))
    }
}
