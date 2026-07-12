import Testing
import CoreGraphics
@testable import SXAnnotate

@MainActor @Suite struct EditorModelTests {
    private func base(_ w: Int = 100, _ h: Int = 100) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    @Test func drawingARectangleAppendsOneAnnotation() {
        let m = EditorModel(baseImage: base())
        m.setTool(.rectangle)
        m.pointerDown(at: CGPoint(x: 10, y: 10))
        m.pointerDragged(to: CGPoint(x: 60, y: 40))
        m.pointerUp(at: CGPoint(x: 60, y: 40))
        #expect(m.annotations.count == 1)
        #expect(m.annotations[0].bounds == CGRect(x: 10, y: 10, width: 50, height: 30))
        #expect(m.selectedID == m.annotations[0].id)
        #expect(m.canUndo)
    }

    @Test func degenerateDraftIsDiscarded() {
        let m = EditorModel(baseImage: base())
        m.setTool(.rectangle)
        m.pointerDown(at: CGPoint(x: 10, y: 10))
        m.pointerDragged(to: CGPoint(x: 11, y: 11))   // below the 3x3 threshold
        m.pointerUp(at: CGPoint(x: 11, y: 11))
        #expect(m.annotations.isEmpty)
        #expect(!m.canUndo)
    }

    @Test func drawingUsesTheCurrentStyle() {
        let m = EditorModel(baseImage: base())
        m.strokeWidth = 9
        m.strokeColor = RGBAColor(r: 0, g: 1, b: 0, a: 1)
        m.setTool(.line)
        m.pointerDown(at: CGPoint(x: 0, y: 0))
        m.pointerDragged(to: CGPoint(x: 40, y: 0))
        m.pointerUp(at: CGPoint(x: 40, y: 0))
        #expect(m.annotations[0].style.strokeWidth == 9)
        #expect(m.annotations[0].style.strokeColor == RGBAColor(r: 0, g: 1, b: 0, a: 1))
    }

    @Test func selectToolMovesAnExistingAnnotation() {
        let m = EditorModel(baseImage: base())
        m.setTool(.rectangle)
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 60, y: 60)); m.pointerUp(at: CGPoint(x: 60, y: 60))
        m.setTool(.select)
        m.pointerDown(at: CGPoint(x: 35, y: 35))   // inside the rect
        m.pointerDragged(to: CGPoint(x: 45, y: 45)) // move by (10,10)
        m.pointerUp(at: CGPoint(x: 45, y: 45))
        #expect(m.annotations[0].bounds == CGRect(x: 20, y: 20, width: 50, height: 50))
    }

    @Test func selectToolResizesViaHandle() {
        let m = EditorModel(baseImage: base())
        m.setTool(.rectangle)
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 60, y: 60)); m.pointerUp(at: CGPoint(x: 60, y: 60))
        m.setTool(.select)
        m.pointerDown(at: CGPoint(x: 10, y: 10))    // grab the top-left handle
        m.pointerDragged(to: CGPoint(x: 0, y: 0))
        m.pointerUp(at: CGPoint(x: 0, y: 0))
        #expect(m.annotations[0].bounds == CGRect(x: 0, y: 0, width: 60, height: 60))
    }

    @Test func clickingEmptySpaceDeselects() {
        let m = EditorModel(baseImage: base())
        m.setTool(.rectangle)
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 40, y: 40)); m.pointerUp(at: CGPoint(x: 40, y: 40))
        m.setTool(.select)
        m.pointerDown(at: CGPoint(x: 90, y: 90)); m.pointerUp(at: CGPoint(x: 90, y: 90))
        #expect(m.selectedID == nil)
    }

    @Test func deleteRemovesTheSelection() {
        let m = EditorModel(baseImage: base())
        m.setTool(.rectangle)
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 40, y: 40)); m.pointerUp(at: CGPoint(x: 40, y: 40))
        m.deleteSelected()
        #expect(m.annotations.isEmpty)
        #expect(m.selectedID == nil)
        #expect(m.canUndo)
    }

    @Test func undoRedoRoundTripsADrawnShape() {
        let m = EditorModel(baseImage: base())
        m.setTool(.ellipse)
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 50, y: 50)); m.pointerUp(at: CGPoint(x: 50, y: 50))
        #expect(m.annotations.count == 1)
        m.undo()
        #expect(m.annotations.isEmpty)
        #expect(m.canRedo)
        m.redo()
        #expect(m.annotations.count == 1)
    }

    @Test func flattenProducesAnImageOfBaseSize() {
        let m = EditorModel(baseImage: base(80, 60))
        m.setTool(.rectangle)
        m.pointerDown(at: CGPoint(x: 5, y: 5)); m.pointerDragged(to: CGPoint(x: 30, y: 30)); m.pointerUp(at: CGPoint(x: 30, y: 30))
        let out = m.flatten()
        #expect(out?.width == 80)
        #expect(out?.height == 60)
    }

    @Test func draggingBlurCreatesABlurWithTheDefaultRadius() {
        let m = EditorModel(baseImage: base())
        m.setTool(.blur)
        m.pointerDown(at: CGPoint(x: 10, y: 10))
        m.pointerDragged(to: CGPoint(x: 60, y: 40))
        m.pointerUp(at: CGPoint(x: 60, y: 40))
        #expect(m.annotations.count == 1)
        if case .blur(let rect, let radius) = m.annotations[0].shape {
            #expect(rect == CGRect(x: 10, y: 10, width: 50, height: 30))
            #expect(radius == AnnotationDefaults.blurRadius)
        } else { Issue.record("expected blur") }
    }

    @Test func draggingPixelateUsesTheModelScale() {
        let m = EditorModel(baseImage: base())
        m.pixelScale = 20
        m.setTool(.pixelate)
        m.pointerDown(at: CGPoint(x: 5, y: 5))
        m.pointerDragged(to: CGPoint(x: 40, y: 40))
        m.pointerUp(at: CGPoint(x: 40, y: 40))
        if case .pixelate(_, let scale) = m.annotations[0].shape {
            #expect(scale == 20)
        } else { Issue.record("expected pixelate") }
    }

    @Test func highlighterAccruesDraggedPoints() {
        let m = EditorModel(baseImage: base())
        m.setTool(.highlighter)
        m.pointerDown(at: CGPoint(x: 5, y: 5))
        m.pointerDragged(to: CGPoint(x: 20, y: 8))
        m.pointerDragged(to: CGPoint(x: 35, y: 20))
        m.pointerUp(at: CGPoint(x: 40, y: 25))
        #expect(m.annotations.count == 1)
        if case .highlighter(let points) = m.annotations[0].shape {
            #expect(points.count >= 3)
            #expect(points.first == CGPoint(x: 5, y: 5))
        } else { Issue.record("expected highlighter") }
    }

    @Test func placingASecondCropReplacesTheFirst() {
        let m = EditorModel(baseImage: base())
        m.setTool(.crop)
        m.pointerDown(at: CGPoint(x: 0, y: 0)); m.pointerDragged(to: CGPoint(x: 50, y: 50)); m.pointerUp(at: CGPoint(x: 50, y: 50))
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 70, y: 70)); m.pointerUp(at: CGPoint(x: 70, y: 70))
        let crops = m.annotations.filter { if case .crop = $0.shape { return true }; return false }
        #expect(crops.count == 1)
        #expect(m.annotations.count == 1)
        if case .crop(let rect) = crops[0].shape {
            #expect(rect == CGRect(x: 10, y: 10, width: 60, height: 60))
        } else { Issue.record("expected crop") }
    }

    @Test func inspectorChangeUpdatesTheSelectedBlur() {
        let m = EditorModel(baseImage: base())
        m.setTool(.blur)
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 60, y: 60)); m.pointerUp(at: CGPoint(x: 60, y: 60))
        // The freshly drawn blur is selected; change the inspector radius and apply.
        m.blurRadius = 25
        m.applyInspectorToSelection()
        if case .blur(_, let radius) = m.annotations[0].shape {
            #expect(radius == 25)
        } else { Issue.record("expected blur") }
        #expect(m.canUndo)
    }
}
