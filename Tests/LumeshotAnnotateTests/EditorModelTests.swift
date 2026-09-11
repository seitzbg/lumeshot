import Testing
import CoreGraphics
@testable import LumeshotAnnotate

@MainActor @Suite struct EditorModelTests {
    private func base(_ w: Int = 100, _ h: Int = 100) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// The canvas maps clicks straight to image coordinates, margins included, so
    /// a crop could be drawn entirely outside the bitmap. It must not become an
    /// annotation at all.
    @Test func aCropDrawnOutsideTheImageIsNotCreated() throws {
        let model = EditorModel(baseImage: base(40, 40))
        model.setTool(.crop)
        model.pointerDown(at: CGPoint(x: -30, y: 10))
        model.pointerUp(at: CGPoint(x: -10, y: 30))
        #expect(model.annotations.isEmpty)
    }

    /// A crop that starts outside is kept, but only the part over the image.
    @Test func aCropStraddlingTheEdgeIsConfinedToTheImage() throws {
        let model = EditorModel(baseImage: base(40, 40))
        model.setTool(.crop)
        model.pointerDown(at: CGPoint(x: -10, y: -10))
        model.pointerUp(at: CGPoint(x: 20, y: 20))
        let annotation = try #require(model.annotations.first)
        guard case .crop(let rect) = annotation.shape else {
            Issue.record("expected a crop"); return
        }
        #expect(rect == CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    // MARK: Crop move against an edge (review fix)

    /// Moving a crop against an image edge and back must restore it exactly. The
    /// move clamps the translation instead of intersecting, so the crop keeps its
    /// size; deriving the move from the gesture-start rectangle keeps edge contact
    /// from accumulating, so returning the cursor returns the crop.
    @Test func movingACropIntoAnEdgeAndBackRestoresItExactly() {
        let m = EditorModel(baseImage: base(100, 100))
        m.setTool(.crop)
        m.pointerDown(at: CGPoint(x: 20, y: 20))
        m.pointerDragged(to: CGPoint(x: 80, y: 80))
        m.pointerUp(at: CGPoint(x: 80, y: 80))            // crop 20…80 (60×60)
        m.setTool(.select)
        m.pointerDown(at: CGPoint(x: 50, y: 50))          // grab its centre
        m.pointerDragged(to: CGPoint(x: 90, y: 50))       // push the right edge past 100…
        m.pointerDragged(to: CGPoint(x: 50, y: 50))       // …then return to the start
        m.pointerUp(at: CGPoint(x: 50, y: 50))
        guard case .crop(let rect) = m.annotations[0].shape else {
            Issue.record("expected a crop"); return
        }
        #expect(rect == CGRect(x: 20, y: 20, width: 60, height: 60))
    }

    /// While pushed against an edge the crop stops at it but keeps its full size,
    /// instead of being shrunk by the part that would cross the boundary.
    @Test func movingACropPastAnEdgeClampsPositionButKeepsSize() {
        let m = EditorModel(baseImage: base(100, 100))
        m.setTool(.crop)
        m.pointerDown(at: CGPoint(x: 20, y: 20)); m.pointerDragged(to: CGPoint(x: 80, y: 80)); m.pointerUp(at: CGPoint(x: 80, y: 80))
        m.setTool(.select)
        m.pointerDown(at: CGPoint(x: 50, y: 50))
        m.pointerDragged(to: CGPoint(x: 90, y: 50))       // +40 in x would run to 60…120
        m.pointerUp(at: CGPoint(x: 90, y: 50))
        guard case .crop(let rect) = m.annotations[0].shape else {
            Issue.record("expected a crop"); return
        }
        #expect(rect == CGRect(x: 40, y: 20, width: 60, height: 60))   // stopped at the edge, size intact
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

    // MARK: No-op inspector apply (post-review fix)

    @Test func noOpInspectorApplySkipsHistoryButARealChangeStillCommitsOnce() {
        let m = EditorModel(baseImage: base())
        m.setTool(.blur)
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 60, y: 60)); m.pointerUp(at: CGPoint(x: 60, y: 60))
        guard case .blur(_, let originalRadius) = m.annotations[0].shape else {
            Issue.record("expected blur"); return
        }
        let canUndoAfterDraw = m.canUndo

        // Same value as the drawn blur — a press-release with no change must not
        // push a no-op entry onto the undo stack.
        m.blurRadius = originalRadius
        m.applyInspectorToSelection()
        #expect(m.canUndo == canUndoAfterDraw)

        // A real value change must still commit exactly once.
        m.blurRadius = originalRadius + 10
        m.applyInspectorToSelection()
        if case .blur(_, let radius) = m.annotations[0].shape {
            #expect(radius == originalRadius + 10)
        } else { Issue.record("expected blur") }

        m.undo()   // undoes the real apply
        if case .blur(_, let radius) = m.annotations[0].shape {
            #expect(radius == originalRadius)
        } else { Issue.record("expected blur") }

        m.undo()   // undoes the draw itself — a spurious no-op entry would need one more undo here
        #expect(m.annotations.isEmpty)
    }

    private func stepNumbers(_ m: EditorModel) -> [Int] {
        m.annotations.compactMap { if case .step(_, let n) = $0.shape { return n }; return nil }
    }

    @Test func textToolClickCreatesOneEmptyTextInEditMode() {
        let m = EditorModel(baseImage: base())
        m.setTool(.text)
        m.pointerDown(at: CGPoint(x: 20, y: 20))
        m.pointerUp(at: CGPoint(x: 20, y: 20))
        #expect(m.annotations.count == 1)
        #expect(m.editingTextID == m.annotations[0].id)
        #expect(m.selectedID == m.annotations[0].id)
        if case .text(_, let string, _) = m.annotations[0].shape {
            #expect(string.isEmpty)
        } else { Issue.record("expected text") }
    }

    @Test func emptyTextIsRemovedWhenEditingEnds() {
        let m = EditorModel(baseImage: base())
        m.setTool(.text)
        m.pointerDown(at: CGPoint(x: 20, y: 20)); m.pointerUp(at: CGPoint(x: 20, y: 20))
        m.endTextEditing()
        #expect(m.annotations.isEmpty)
        #expect(m.editingTextID == nil)
        #expect(!m.canUndo)          // placing-then-abandoning an empty box leaves no history
    }

    @Test func typedTextIsCommittedAsOneUndoStep() {
        let m = EditorModel(baseImage: base())
        m.setTool(.text)
        m.pointerDown(at: CGPoint(x: 20, y: 20)); m.pointerUp(at: CGPoint(x: 20, y: 20))
        m.updateEditingText("Hi")
        m.endTextEditing()
        #expect(m.annotations.count == 1)
        if case .text(_, let string, _) = m.annotations[0].shape { #expect(string == "Hi") }
        else { Issue.record("expected text") }
        #expect(m.editingTextID == nil)
        #expect(m.canUndo)
        m.undo()
        #expect(m.annotations.isEmpty)   // one undo removes the whole text placement
    }

    @Test func stepsAutoNumberInPlacementOrder() {
        let m = EditorModel(baseImage: base())
        m.setTool(.step)
        for p in [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30), CGPoint(x: 50, y: 50)] {
            m.pointerDown(at: p); m.pointerUp(at: p)
        }
        #expect(m.annotations.count == 3)
        #expect(stepNumbers(m) == [1, 2, 3])
    }

    @Test func deletingAMiddleStepRenumbersTheRestInOneUndo() {
        let m = EditorModel(baseImage: base())
        m.setTool(.step)
        for p in [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30), CGPoint(x: 50, y: 50)] {
            m.pointerDown(at: p); m.pointerUp(at: p)
        }
        m.setTool(.select)
        m.pointerDown(at: CGPoint(x: 30, y: 30)); m.pointerUp(at: CGPoint(x: 30, y: 30))   // select middle step
        m.deleteSelected()
        #expect(m.annotations.count == 2)
        #expect(stepNumbers(m) == [1, 2])   // 1,3 resequenced to 1,2
        m.undo()
        #expect(m.annotations.count == 3)   // delete + renumber undo together
        #expect(stepNumbers(m) == [1, 2, 3])
    }

    @Test func changingFontSizeUpdatesTheSelectedText() {
        let m = EditorModel(baseImage: base())
        m.setTool(.text)
        m.pointerDown(at: CGPoint(x: 20, y: 20)); m.pointerUp(at: CGPoint(x: 20, y: 20))
        m.updateEditingText("Hi")
        m.endTextEditing()               // text stays selected after editing
        m.textFontSize = 40
        m.applyInspectorToSelection()
        if case .text(_, _, let fontSize) = m.annotations[0].shape { #expect(fontSize == 40) }
        else { Issue.record("expected text") }
    }

    // MARK: Re-entrancy guard (review fix)

    @Test func reEnteringTextEditingDiscardsAnEmptyPreviousBox() {
        let m = EditorModel(baseImage: base())
        m.setTool(.text)
        m.beginTextEditing(at: CGPoint(x: 20, y: 20))
        let firstID = m.editingTextID
        m.beginTextEditing(at: CGPoint(x: 60, y: 60))
        #expect(m.annotations.count == 1)   // the empty first box was cleaned up, not orphaned
        #expect(!m.annotations.contains { $0.id == firstID })
        #expect(m.editingTextID == m.annotations[0].id)
        #expect(m.editingTextID != firstID)
        #expect(!m.canUndo)   // first was empty (no history entry); second is still in progress
    }

    @Test func reEnteringTextEditingCommitsANonEmptyPreviousBox() {
        let m = EditorModel(baseImage: base())
        m.setTool(.text)
        m.beginTextEditing(at: CGPoint(x: 20, y: 20))
        let firstID = m.editingTextID
        m.updateEditingText("Hello")
        m.beginTextEditing(at: CGPoint(x: 60, y: 60))
        #expect(m.annotations.count == 2)   // the non-empty first box is kept, not orphaned
        if let first = m.annotations.first(where: { $0.id == firstID }),
           case .text(_, let string, _) = first.shape {
            #expect(string == "Hello")
        } else { Issue.record("expected first text kept") }
        #expect(m.editingTextID != firstID)
        #expect(m.editingTextID == m.annotations.first { $0.id != firstID }?.id)
        #expect(m.canUndo)   // the first box's placement committed as its own history step
    }

    // MARK: Whitespace-only discard (review fix)

    @Test func whitespaceOnlyTextIsRemovedWhenEditingEnds() {
        let m = EditorModel(baseImage: base())
        m.setTool(.text)
        m.beginTextEditing(at: CGPoint(x: 20, y: 20))
        m.updateEditingText("   \n  ")
        m.endTextEditing()
        #expect(m.annotations.isEmpty)
        #expect(m.editingTextID == nil)
        #expect(!m.canUndo)
    }

    @Test func nonEmptyTextIsKeptWhenEditingEnds() {
        let m = EditorModel(baseImage: base())
        m.setTool(.text)
        m.beginTextEditing(at: CGPoint(x: 20, y: 20))
        m.updateEditingText("hi")
        m.endTextEditing()
        #expect(m.annotations.count == 1)
        if case .text(_, let string, _) = m.annotations[0].shape { #expect(string == "hi") }
        else { Issue.record("expected text") }
        #expect(m.editingTextID == nil)
        #expect(m.canUndo)
    }

    @Test func drawingFreehandAccruesPointsIntoOneAnnotation() {
        let m = EditorModel(baseImage: base())
        m.setTool(.freehand)
        m.pointerDown(at: CGPoint(x: 10, y: 10))
        m.pointerDragged(to: CGPoint(x: 20, y: 15))
        m.pointerDragged(to: CGPoint(x: 30, y: 25))
        m.pointerUp(at: CGPoint(x: 30, y: 25))
        #expect(m.annotations.count == 1)
        if case .freehand(let points) = m.annotations[0].shape {
            #expect(points.count == 4)                       // anchor + 2 drags + up
            #expect(points.first == CGPoint(x: 10, y: 10))
            #expect(points.last == CGPoint(x: 30, y: 25))
        } else { Issue.record("expected freehand") }
        #expect(m.selectedID == m.annotations[0].id)
        #expect(m.canUndo)
    }

    @Test func drawingAnArrowAppendsOneAnnotation() {
        let m = EditorModel(baseImage: base())
        m.setTool(.arrow)
        m.pointerDown(at: CGPoint(x: 5, y: 5))
        m.pointerDragged(to: CGPoint(x: 40, y: 30))
        m.pointerUp(at: CGPoint(x: 40, y: 30))
        #expect(m.annotations.count == 1)
        if case .arrow(let s, let e) = m.annotations[0].shape {
            #expect(s == CGPoint(x: 5, y: 5))
            #expect(e == CGPoint(x: 40, y: 30))
        } else { Issue.record("expected arrow") }
    }

    @Test func displayAnnotationsIncludesInProgressDraft() {
        let m = EditorModel(baseImage: base())
        m.setTool(.rectangle)
        m.pointerDown(at: CGPoint(x: 10, y: 10))
        m.pointerDragged(to: CGPoint(x: 50, y: 40))
        // Mid-gesture: the draft is not yet in `annotations`…
        #expect(m.annotations.isEmpty)
        // …but it appears in `displayAnnotations` for live rendering.
        #expect(m.displayAnnotations.count == 1)
        m.pointerUp(at: CGPoint(x: 50, y: 40))
        #expect(m.annotations.count == 1)
        #expect(m.displayAnnotations.count == 1)
    }

    @Test func selectingABlurAnnotationSyncsBlurRadiusFromItsShape() {
        let m = EditorModel(baseImage: base())
        m.setTool(.blur)
        m.blurRadius = 12
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 40, y: 40)); m.pointerUp(at: CGPoint(x: 40, y: 40))
        m.blurRadius = 30   // simulate the inspector default drifting after drawing
        m.setTool(.select)
        m.pointerDown(at: CGPoint(x: 25, y: 25))   // inside the blur rect
        #expect(m.blurRadius == 12)
    }

    @Test func selectingAnAnnotationSyncsStrokeColorAndWidth() {
        let m = EditorModel(baseImage: base())
        m.strokeWidth = 9
        m.strokeColor = RGBAColor(r: 0, g: 1, b: 0, a: 1)
        m.setTool(.rectangle)
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 60, y: 60)); m.pointerUp(at: CGPoint(x: 60, y: 60))
        m.strokeWidth = 2
        m.strokeColor = .red
        m.setTool(.select)
        m.pointerDown(at: CGPoint(x: 35, y: 35))   // inside the rect
        #expect(m.strokeWidth == 9)
        #expect(m.strokeColor == RGBAColor(r: 0, g: 1, b: 0, a: 1))
    }

    /// The P3 walk-through from `docs/smoke-m5b.md`: three annotations with
    /// three different inspector values, selected one after another. Covers the
    /// pixelate and text arms of the sync — and, more to the point, that
    /// *changing* the selection re-syncs rather than leaving the previous
    /// annotation's values in the toolbar.
    @Test func selectingEachAnnotationInTurnSyncsThatOnesInspectorValue() {
        let m = EditorModel(baseImage: base())

        m.setTool(.blur)
        m.blurRadius = 12
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 40, y: 40)); m.pointerUp(at: CGPoint(x: 40, y: 40))

        m.setTool(.pixelate)
        m.pixelScale = 24
        m.pointerDown(at: CGPoint(x: 60, y: 10)); m.pointerDragged(to: CGPoint(x: 90, y: 40)); m.pointerUp(at: CGPoint(x: 90, y: 40))

        m.setTool(.text)
        m.textFontSize = 37
        m.pointerDown(at: CGPoint(x: 10, y: 60)); m.pointerUp(at: CGPoint(x: 10, y: 60))
        m.updateEditingText("Hi")   // an empty box is discarded on endTextEditing
        m.endTextEditing()

        // Drift every inspector value away from all three, the way drawing with
        // a later tool would.
        m.blurRadius = 99; m.pixelScale = 99; m.textFontSize = 99

        m.setTool(.select)
        m.pointerDown(at: CGPoint(x: 25, y: 25))     // the blur
        #expect(m.blurRadius == 12)
        m.pointerDown(at: CGPoint(x: 75, y: 25))     // the pixelate
        #expect(m.pixelScale == 24)
        m.pointerDown(at: CGPoint(x: 12, y: 62))     // the text
        #expect(m.textFontSize == 37)
        // Selecting the blur again must not have been left holding the text's size.
        m.pointerDown(at: CGPoint(x: 25, y: 25))
        #expect(m.blurRadius == 12)
    }

    @Test func applyInspectorToSelectionUpdatesTheJustSyncedBlurAnnotation() {
        let m = EditorModel(baseImage: base())
        m.setTool(.blur)
        m.blurRadius = 12
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 40, y: 40)); m.pointerUp(at: CGPoint(x: 40, y: 40))
        m.setTool(.select)
        m.pointerDown(at: CGPoint(x: 25, y: 25))   // selects + syncs blurRadius to 12
        m.blurRadius = 20                          // simulated inspector edit
        m.applyInspectorToSelection()
        guard case .blur(_, let radius) = m.annotations[0].shape else {
            Issue.record("expected .blur shape"); return
        }
        #expect(radius == 20)
    }

    // MARK: Stroke push from the toolbar

    private let blue = RGBAColor(r: 0, g: 0, b: 1, a: 1)
    private let green = RGBAColor(r: 0, g: 1, b: 0, a: 1)

    private func modelWithSelectedRectangle() -> EditorModel {
        let m = EditorModel(baseImage: base())
        m.setTool(.rectangle)
        m.pointerDown(at: CGPoint(x: 10, y: 10))
        m.pointerDragged(to: CGPoint(x: 60, y: 40))
        m.pointerUp(at: CGPoint(x: 60, y: 40))
        return m
    }

    private func strokeColor(_ m: EditorModel) -> RGBAColor { m.annotations[0].style.strokeColor }
    private func strokeWidth(_ m: EditorModel) -> Double { m.annotations[0].style.strokeWidth }

    @Test func strokeColorAppliesToTheSelectedAnnotation() {
        let m = modelWithSelectedRectangle()
        m.strokeColor = blue
        m.applyStrokeColorToSelection()
        #expect(strokeColor(m) == blue)
    }

    @Test func strokeWidthAppliesToTheSelectedAnnotation() {
        let m = modelWithSelectedRectangle()
        m.strokeWidth = 11
        m.applyStrokeWidthToSelection()
        #expect(strokeWidth(m) == 11)
    }

    @Test func strokeStyleDoesNothingWithoutASelection() {
        let m = modelWithSelectedRectangle()
        let before = m.annotations[0].style
        m.setTool(.line)                  // leaving .select clears the selection
        #expect(m.selectedID == nil)
        m.strokeColor = blue
        m.applyStrokeColorToSelection()
        #expect(m.annotations[0].style == before)
    }

    /// A ColorPicker drag arrives as many changes with no release event. One undo must
    /// return to the colour the run started from, not an intermediate value.
    @Test func aRunOfColourChangesCoalescesIntoOneUndoEntry() {
        let m = modelWithSelectedRectangle()
        let original = strokeColor(m)
        for step in 1...5 {
            m.strokeColor = RGBAColor(r: Double(step) / 5, g: 0, b: 0, a: 1)
            m.applyStrokeColorToSelection()
        }
        #expect(strokeColor(m) == RGBAColor(r: 1, g: 0, b: 0, a: 1))
        m.undo()
        #expect(strokeColor(m) == original)
    }

    @Test func aNewRunStartsAfterTheSelectionChanges() {
        let m = modelWithSelectedRectangle()
        let original = strokeColor(m)
        m.strokeColor = blue
        m.applyStrokeColorToSelection()

        m.setTool(.select)
        m.pointerDown(at: CGPoint(x: 90, y: 90))
        m.pointerUp(at: CGPoint(x: 90, y: 90))
        #expect(m.selectedID == nil)
        m.pointerDown(at: CGPoint(x: 30, y: 25))
        m.pointerUp(at: CGPoint(x: 30, y: 25))
        #expect(m.selectedID == m.annotations[0].id)

        m.strokeColor = green
        m.applyStrokeColorToSelection()
        m.undo()
        #expect(strokeColor(m) == blue)
        m.undo()
        #expect(strokeColor(m) == original)
    }

    /// Undo restores the document but not the toolbar's published values. If a later
    /// width edit copied the colour too, it would silently reinstate the colour the
    /// user just undid.
    @Test func aWidthEditDoesNotRestoreAnUndoneColour() {
        let m = modelWithSelectedRectangle()
        let original = strokeColor(m)
        m.strokeColor = blue
        m.applyStrokeColorToSelection()
        m.undo()
        #expect(strokeColor(m) == original)

        m.strokeWidth = 17
        m.applyStrokeWidthToSelection()
        #expect(strokeWidth(m) == 17)
        #expect(strokeColor(m) == original)   // must not have gone blue again
    }

    /// The mirror image: a colour edit must not reinstate an undone width.
    @Test func aColourEditDoesNotRestoreAnUndoneWidth() {
        let m = modelWithSelectedRectangle()
        let original = strokeWidth(m)
        m.strokeWidth = 17
        m.applyStrokeWidthToSelection()
        m.undo()
        #expect(strokeWidth(m) == original)

        m.strokeColor = green
        m.applyStrokeColorToSelection()
        #expect(strokeColor(m) == green)
        #expect(strokeWidth(m) == original)
    }

    /// Colour then width: the width edit must not absorb the colour change into its
    /// own undo entry, which would make one undo discard both.
    @Test func aWidthEditDoesNotAbsorbThePrecedingColourChange() {
        let m = modelWithSelectedRectangle()
        let originalWidth = strokeWidth(m)
        m.strokeColor = blue
        m.applyStrokeColorToSelection()
        m.strokeWidth = 17
        m.applyStrokeWidthToSelection()

        m.undo()
        #expect(strokeWidth(m) == originalWidth)   // only the width came back
        #expect(strokeColor(m) == blue)            // the colour edit survives
    }

    /// The view ends the run on slider grab, but the fix must not depend on the view
    /// remembering to: a non-coalescing apply commits its own entry regardless.
    @Test func endingTheRunExplicitlyIsNotRequiredForASeparateEntry() {
        let m = modelWithSelectedRectangle()
        m.strokeColor = blue
        m.applyStrokeColorToSelection()
        m.endStrokeStyleRun()
        m.strokeWidth = 17
        m.applyStrokeWidthToSelection()
        m.undo()
        #expect(strokeColor(m) == blue)
    }

    @Test func undoResyncsTheInspectorToTheSelection() {
        let m = modelWithSelectedRectangle()
        let original = strokeColor(m)
        m.strokeColor = blue
        m.applyStrokeColorToSelection()
        m.undo()
        #expect(m.strokeColor == original)   // the toolbar follows the document
    }

    @Test func aNoOpStrokePushDoesNotTouchHistory() {
        let m = modelWithSelectedRectangle()
        m.applyStrokeColorToSelection()
        m.undo()
        #expect(m.annotations.isEmpty)
    }

    // MARK: Resize handle across the opposite edge (review fix)

    /// Dragging a resize handle past the opposite edge and back must leave the
    /// opposite (anchored) edge where it was. The resize used to be derived from
    /// the previously-standardized rectangle, so once the grabbed edge crossed
    /// the far one, standardization swapped them while `activeHandle` kept its
    /// identity — subsequent events then dragged the wrong edge and moved the
    /// anchor. Here the crop's right edge (x=80) must stay put.
    @Test func resizingAHandlePastTheOppositeEdgeAndBackKeepsTheAnchor() {
        let m = EditorModel(baseImage: base(100, 100))
        m.setTool(.crop)
        m.pointerDown(at: CGPoint(x: 20, y: 20))
        m.pointerDragged(to: CGPoint(x: 80, y: 80))
        m.pointerUp(at: CGPoint(x: 80, y: 80))            // crop 20…80 (60×60)
        m.setTool(.select)
        m.pointerDown(at: CGPoint(x: 20, y: 50))          // grab the LEFT edge handle
        m.pointerDragged(to: CGPoint(x: 90, y: 50))       // drag it past the right edge (80)…
        m.pointerDragged(to: CGPoint(x: 100, y: 50))      // …further out…
        m.pointerDragged(to: CGPoint(x: 20, y: 50))       // …then back to where it started
        m.pointerUp(at: CGPoint(x: 20, y: 50))
        guard case .crop(let rect) = m.annotations[0].shape else {
            Issue.record("expected a crop"); return
        }
        #expect(rect == CGRect(x: 20, y: 20, width: 60, height: 60))
    }

    // MARK: Text stays visible after a font-size change (review fix)

    /// A committed text box has a fixed height sized to its original font. The
    /// inspector used to change only the font size, keeping that box; a larger
    /// font then no longer fit the box CoreText clips to, so the export drew no
    /// text at all while still "succeeding". The box must grow to fit.
    @Test func enlargingTextKeepsItInTheFlattenedImage() throws {
        let m = EditorModel(baseImage: base(400, 200))
        m.strokeColor = .red
        m.setTool(.text)
        m.pointerDown(at: CGPoint(x: 10, y: 10))          // places an empty text box, enters edit
        m.pointerUp(at: CGPoint(x: 10, y: 10))
        m.updateEditingText("Hello")
        m.endTextEditing()                                 // commits the non-empty placement

        let before = Self.countRed(try #require(m.flatten()))
        #expect(before > 0)                                // sanity: text renders at the default size

        m.textFontSize = 96
        m.applyInspectorToSelection()                      // change only the font size
        #expect(Self.countRed(try #require(m.flatten())) > 0)   // the enlarged text is still exported
    }

    /// Counts pixels that are predominantly red (the text colour) in a flattened
    /// bitmap, so "the text disappeared" is an assertion about actual output.
    private static func countRed(_ image: CGImage) -> Int {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var count = 0, i = 0
        while i < buf.count {
            if buf[i] > 200, buf[i + 1] < 80, buf[i + 2] < 80 { count += 1 }
            i += 4
        }
        return count
    }
}
