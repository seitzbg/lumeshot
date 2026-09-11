import CoreGraphics
import Combine
import Foundation

/// The interaction state machine and document owner for one editing session.
/// UI-agnostic: the AppKit canvas forwards pointer events (in image coordinates)
/// and observes the published state. All mutation flows through here so undo
/// history and selection stay consistent.
@MainActor
public final class EditorModel: ObservableObject {
    public let baseImage: CGImage

    @Published public private(set) var annotations: [Annotation] = []
    @Published public private(set) var activeTool: EditorTool = .select
    @Published public var strokeColor: RGBAColor = .red
    @Published public var strokeWidth: Double = 4
    @Published public var blurRadius: Double = AnnotationDefaults.blurRadius
    @Published public var pixelScale: Double = AnnotationDefaults.pixelScale
    @Published public var textFontSize: Double = AnnotationDefaults.textFontSize
    @Published public private(set) var editingTextID: Annotation.ID?
    @Published public private(set) var selectedID: Annotation.ID? {
        didSet { if selectedID != oldValue { styleEditRun = nil } }
    }
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false

    /// Interaction tolerances are authored in *view points* — the units the
    /// cursor actually moves in — and divided by the canvas scale before
    /// hit-testing in image space.
    ///
    /// They used to be fixed image-pixel values while the selection handles
    /// were always drawn 8×8 view points. On a 4K image fitted into a 900-point
    /// window (scale ≈ 0.22) a 9-pixel tolerance is about 2 view points, so a
    /// handle four times that size on screen was nearly unclickable, and thin
    /// lines were worse.
    public static let hitTolerancePoints: CGFloat = 8
    public static let handleTolerancePoints: CGFloat = 9

    /// Current image-pixels-per-view-point, pushed in by the canvas whenever
    /// its geometry changes. 1 means "no scaling" — the safe default for
    /// headless use and tests.
    @Published public var canvasScale: CGFloat = 1

    /// Guarded against zero/NaN: a canvas can momentarily report an empty size
    /// during layout, and dividing by it would make every hit test match.
    private var pointsToImage: CGFloat {
        canvasScale.isFinite && canvasScale > 0.0001 ? 1 / canvasScale : 1
    }

    public var hitTolerance: CGFloat { Self.hitTolerancePoints * pointsToImage }
    public var handleTolerance: CGFloat { Self.handleTolerancePoints * pointsToImage }

    private var history = AnnotationHistory()

    // Per-gesture transient state.
    private var draft: Annotation?           // shape being drawn
    private var drawAnchor: CGPoint?         // draw start point
    private var activeHandle: HandleKind?    // resize in progress
    // Like a move, a resize is derived from the gesture-start snapshot, not the
    // previously-resized rectangle. Feeding the standardized intermediate back in
    // let a handle dragged across the opposite edge swap which edge it drives —
    // the "fixed" anchor would then start to move once the drag crossed over.
    private var resizeStartAnnotation: Annotation?  // the annotation when the resize began
    // A move is derived from the gesture-start snapshot plus the total offset
    // from the pointer-down anchor — never accumulated event-to-event. Clamping
    // a crop at an edge must not feed back into the next event's starting point,
    // or dragging to an edge and back would leave the crop shifted and shrunken.
    private var moveAnchor: CGPoint?              // pointer-down point of a move
    private var moveStartAnnotation: Annotation?  // the annotation when the move began
    private var gestureStartState: [Annotation]?  // document before the gesture
    private var textEditStartState: [Annotation]?   // document before a text placement

    public init(baseImage: CGImage) {
        self.baseImage = baseImage
    }

    public var selectedAnnotation: Annotation? {
        guard let id = selectedID else { return nil }
        return annotations.first { $0.id == id }
    }

    /// The document plus any in-progress draft, for live rendering.
    public var displayAnnotations: [Annotation] {
        if let draft { return annotations + [draft] }
        return annotations
    }

    public func setTool(_ tool: EditorTool) {
        activeTool = tool
        if tool != .select { selectedID = nil }
    }

    /// The annotation currently absorbing a run of style edits, or nil when no run
    /// is open. See `applyStrokeColorToSelection`.
    private var styleEditRun: Annotation.ID?

    private var currentStyle: AnnotationStyle {
        AnnotationStyle(strokeColor: strokeColor, strokeWidth: strokeWidth, fillColor: .clear)
    }

    // MARK: Pointer handling

    public func pointerDown(at point: CGPoint) {
        switch activeTool {
        case .text:
            beginTextEditing(at: point)   // click-placed; no draft, no drag commit
            return
        case .step:
            placeStep(at: point)          // click-placed; commits immediately
            return
        default:
            break
        }
        gestureStartState = annotations
        if activeTool == .select {
            beginSelectGesture(at: point)
        } else {
            beginDraw(at: point)
        }
    }

    public func pointerDragged(to point: CGPoint) {
        if draft != nil, let anchor = drawAnchor {
            draft = updatedDraft(anchor: anchor, to: point)
        } else if let handle = activeHandle, let start = resizeStartAnnotation, let id = selectedID,
                  let index = annotations.firstIndex(where: { $0.id == id }) {
            let resized = start.resized(handle: handle, to: point)
            // A crop dragged past an edge stops at it instead of leaving the
            // image; anything that would leave nothing behind is not applied.
            if let clamped = clampedToImage(resized) { annotations[index] = clamped }
        } else if let anchor = moveAnchor, let start = moveStartAnnotation, let id = selectedID,
                  let index = annotations.firstIndex(where: { $0.id == id }) {
            let delta = CGVector(dx: point.x - anchor.x, dy: point.y - anchor.y)
            annotations[index] = clampedMove(start.moved(by: delta))
        }
    }

    public func pointerUp(at point: CGPoint) {
        if draft != nil, let anchor = drawAnchor {
            let finished = clampedToImage(updatedDraft(anchor: anchor, to: point))
            if let finished, isNonDegenerate(finished) {
                if case .crop = finished.shape {
                    annotations.removeAll { if case .crop = $0.shape { return true }; return false }
                }
                annotations.append(finished)
                selectedID = finished.id
            }
        }
        commitGestureIfChanged()
        draft = nil
        drawAnchor = nil
        activeHandle = nil
        resizeStartAnnotation = nil
        moveAnchor = nil
        moveStartAnnotation = nil
    }

    // MARK: Commands

    public func deleteSelected() {
        guard let id = selectedID, let target = annotations.first(where: { $0.id == id }) else { return }
        commitHistory(annotations)
        let deletedAStep: Bool
        if case .step = target.shape { deletedAStep = true } else { deletedAStep = false }
        annotations.removeAll { $0.id == id }
        if deletedAStep { renumberSteps() }
        selectedID = nil
        refreshHistoryFlags()
    }

    /// Re-sequences remaining step badges to 1…n in z-order (== their numeric order,
    /// since steps are only appended in increasing number and never reordered in M3b).
    private func renumberSteps() {
        var n = 1
        for i in annotations.indices {
            if case .step(let center, _) = annotations[i].shape {
                annotations[i].shape = .step(center: center, number: n)
                n += 1
            }
        }
    }

    public func undo() {
        styleEditRun = nil
        guard let previous = history.undo(current: annotations) else { return }
        annotations = previous
        clampSelection()
        syncInspectorToSelection()
        refreshHistoryFlags()
    }

    public func redo() {
        styleEditRun = nil
        guard let next = history.redo(current: annotations) else { return }
        annotations = next
        clampSelection()
        syncInspectorToSelection()
        refreshHistoryFlags()
    }

    public func flatten() -> CGImage? {
        AnnotationRenderer.flatten(base: baseImage, annotations: annotations)
    }

    /// Snapshots history and ends any open style-edit run, so an unrelated edit
    /// cannot be absorbed into a run of colour changes.
    private func commitHistory(_ state: [Annotation]) {
        history.commit(state)
        styleEditRun = nil
    }

    /// Pushes the toolbar's stroke colour onto the selected annotation.
    ///
    /// `ColorPicker` has no `onEditingChanged`, so dragging through the colour wheel
    /// emits a continuous stream of values with no release event to commit on. One
    /// history entry per value would bury the undo stack, so consecutive colour edits
    /// to the *same* annotation coalesce: the first snapshots history, the rest mutate
    /// in place. A run ends on selection change, undo/redo, any other edit, or
    /// `endStrokeStyleRun()`.
    ///
    /// The accepted cost: two deliberate colour picks with nothing in between merge
    /// into one undo entry. Without a release event the alternative is a timer, which
    /// buys little for a cosmetic edit.
    public func applyStrokeColorToSelection() {
        applyStroke(coalescing: true) { $0.strokeColor = self.strokeColor }
    }

    /// Pushes the toolbar's stroke width onto the selected annotation as its own undo
    /// entry. The slider has a real release event, so there is no reason to coalesce —
    /// and coalescing here would let a width edit swallow a preceding colour change.
    public func applyStrokeWidthToSelection() {
        applyStroke(coalescing: false) { $0.strokeWidth = self.strokeWidth }
    }

    /// Ends any open style-edit run. Call when a new interaction begins (a slider
    /// grab), so the edit that follows cannot merge backwards into it.
    public func endStrokeStyleRun() { styleEditRun = nil }

    /// Applies ONE property. Applying both would be wrong: undo restores `annotations`
    /// but not the toolbar's published values, so after undoing a colour change the
    /// picker still holds the new colour — and copying it alongside a width edit would
    /// silently re-apply the colour the user just undid.
    private func applyStroke(coalescing: Bool, _ mutate: (inout AnnotationStyle) -> Void) {
        guard let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }) else {
            styleEditRun = nil
            return
        }
        var style = annotations[index].style
        mutate(&style)
        guard style != annotations[index].style else {
            if !coalescing { styleEditRun = nil }
            return
        }
        if !(coalescing && styleEditRun == id) {
            commitHistory(annotations)              // also clears styleEditRun
            styleEditRun = coalescing ? id : nil
        }
        annotations[index].style = style
        refreshHistoryFlags()
    }

    /// Applies the current inspector params (`blurRadius`/`pixelScale`) to the
    /// selected effect annotation, if it matches. One history commit per apply.
    public func applyInspectorToSelection() {
        guard let id = selectedID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let updated: AnnotationShape?
        switch annotations[index].shape {
        case .blur(let rect, _):        updated = .blur(rect: rect, radius: blurRadius)
        case .pixelate(let rect, _):    updated = .pixelate(rect: rect, scale: pixelScale)
        case .text(let rect, let str, _):
            // Grow the box so the new font still fits: CoreText clips to the box,
            // so a larger font in the old (smaller) box would render nothing.
            // Keep the origin and wrapping width; never shrink below the current
            // height, so a manually enlarged box is preserved.
            let std = rect.standardized
            let height = Swift.max(std.height,
                                   TextBoxLayout.fittingHeight(string: str, fontSize: textFontSize, width: std.width))
            let box = CGRect(x: std.minX, y: std.minY, width: std.width, height: height)
            updated = .text(rect: box, string: str, fontSize: textFontSize)
        default:                        updated = nil
        }
        // Wired to slider/stepper release, so a press-release with no actual value
        // change must not push a no-op entry onto the undo stack.
        guard let newShape = updated, newShape != annotations[index].shape else { return }
        commitHistory(annotations)
        annotations[index].shape = newShape
        refreshHistoryFlags()
    }

    /// Places an empty text box at `point`, enters edit mode and selects it. The
    /// placement is committed to history only when non-empty text is finalized
    /// (see `endTextEditing`), so abandoning an empty box leaves no undo step.
    public func beginTextEditing(at point: CGPoint) {
        // Re-entrancy guard: a text placement that's still active when a new one
        // begins (e.g. clicking the .text tool down again before finalizing) would
        // otherwise be orphaned — silently abandoned with no undo entry, and if it
        // was left empty it would never be cleaned up. Finalize it first so the
        // usual empty-discard / non-empty-commit rules apply before we start fresh.
        if editingTextID != nil { endTextEditing() }
        textEditStartState = annotations
        let box = CGRect(x: point.x, y: point.y, width: 200, height: textFontSize * 1.5)
        let text = Annotation(shape: .text(rect: box, string: "", fontSize: textFontSize), style: currentStyle)
        annotations.append(text)
        selectedID = text.id
        editingTextID = text.id
    }

    /// Live-updates the editing text's string without a per-keystroke commit.
    public func updateEditingText(_ string: String) {
        guard let id = editingTextID,
              let index = annotations.firstIndex(where: { $0.id == id }),
              case .text(let rect, _, let fontSize) = annotations[index].shape else { return }
        annotations[index].shape = .text(rect: rect, string: string, fontSize: fontSize)
    }

    /// Ends text editing. Empty boxes are discarded with no history entry; a
    /// non-empty box commits the placement as a single undo step.
    public func endTextEditing() {
        defer { editingTextID = nil }
        guard let id = editingTextID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        if case .text(_, let string, _) = annotations[index].shape,
           string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            annotations.remove(at: index)
            if selectedID == id { selectedID = nil }
            textEditStartState = nil
            return
        }
        if let before = textEditStartState {
            commitHistory(before)
            textEditStartState = nil
            refreshHistoryFlags()
        }
    }

    // MARK: Gesture internals

    private func beginSelectGesture(at point: CGPoint) {
        // Resize takes priority when a selected shape's handle is under the cursor.
        if let selected = selectedAnnotation,
           let handle = selected.handle(at: point, tolerance: handleTolerance) {
            activeHandle = handle
            resizeStartAnnotation = selected
            return
        }
        // Otherwise pick the topmost annotation under the point.
        if let hit = annotations.last(where: { $0.hitTest(point, tolerance: hitTolerance) }) {
            selectedID = hit.id
            moveAnchor = point
            moveStartAnnotation = hit
            syncInspector(to: hit)
        } else {
            selectedID = nil
        }
    }

    /// Mirrors the selected annotation's real values into the published inspector
    /// vars, so the toolbar reflects the selection instead of stale values left
    /// over from whatever tool was last drawn with.
    private func syncInspector(to annotation: Annotation) {
        strokeColor = annotation.style.strokeColor
        strokeWidth = annotation.style.strokeWidth
        switch annotation.shape {
        case .blur(_, let radius):      blurRadius = radius
        case .pixelate(_, let scale):   pixelScale = scale
        case .text(_, _, let fontSize): textFontSize = fontSize
        default: break
        }
    }

    private func beginDraw(at point: CGPoint) {
        drawAnchor = point
        draft = Annotation(shape: shape(for: activeTool, anchor: point, to: point),
                           style: currentStyle)
    }

    /// The next unused step badge number (max existing + 1).
    private var nextStepNumber: Int {
        let maxNumber = annotations.reduce(0) { acc, ann in
            if case .step(_, let number) = ann.shape { return Swift.max(acc, number) }
            return acc
        }
        return maxNumber + 1
    }

    /// Places an auto-numbered step badge at `point` and selects it (one commit).
    private func placeStep(at point: CGPoint) {
        commitHistory(annotations)
        let step = Annotation(shape: .step(center: point, number: nextStepNumber), style: currentStyle)
        annotations.append(step)
        selectedID = step.id
        refreshHistoryFlags()
    }

    private func shape(for tool: EditorTool, anchor: CGPoint, to point: CGPoint) -> AnnotationShape {
        switch tool {
        case .rectangle: return .rectangle(rect: CGRect(spanning: anchor, point))
        case .ellipse:   return .ellipse(rect: CGRect(spanning: anchor, point))
        case .line:      return .line(start: anchor, end: point)
        case .arrow:     return .arrow(start: anchor, end: point)
        case .freehand:  return .freehand(points: [anchor])
        // M3b drag tools:
        case .crop:      return .crop(rect: CGRect(spanning: anchor, point))
        case .blur:      return .blur(rect: CGRect(spanning: anchor, point), radius: blurRadius)
        case .pixelate:  return .pixelate(rect: CGRect(spanning: anchor, point), scale: pixelScale)
        case .highlighter: return .highlighter(points: [anchor])
        // Click-placed in Task 7; unreachable via beginDraw.
        case .text:      return .text(rect: CGRect(spanning: anchor, point), string: "", fontSize: AnnotationDefaults.textFontSize)
        case .step:      return .step(center: point, number: 0)
        case .select:    return .rectangle(rect: CGRect(spanning: anchor, point))   // unreachable
        }
    }

    private func updatedDraft(anchor: CGPoint, to point: CGPoint) -> Annotation {
        guard var current = draft else {
            return Annotation(shape: shape(for: activeTool, anchor: anchor, to: point), style: currentStyle)
        }
        // Point-accruing tools append the new point to the existing draft; every
        // span-based tool re-derives its shape from the anchor→point span via the
        // single source of truth, `shape(for:)`.
        switch current.shape {
        case .freehand(var points):
            points.append(point)
            current.shape = .freehand(points: points)
        case .highlighter(var points):
            points.append(point)
            current.shape = .highlighter(points: points)
        default:
            current.shape = shape(for: activeTool, anchor: anchor, to: point)
        }
        return current
    }

    /// Confines a crop to the base image, returning nil when nothing of it is
    /// left inside.
    ///
    /// The canvas maps clicks straight to image coordinates, margins included,
    /// so a crop could be drawn or dragged entirely outside the bitmap. Export
    /// intersected such a crop to nothing and fell through to the uncropped
    /// image — handing over exactly the content the crop was meant to remove.
    /// Non-crop shapes are returned untouched: an arrow may legitimately run
    /// past an edge, because it is drawn, not used to select pixels.
    private func clampedToImage(_ annotation: Annotation) -> Annotation? {
        guard case .crop(let rect) = annotation.shape else { return annotation }
        let bounds = CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height)
        let clamped = rect.standardized.intersection(bounds)
        guard !clamped.isNull, !clamped.isEmpty else { return nil }
        var result = annotation
        result.shape = .crop(rect: clamped)
        return result
    }

    /// Confines a *moved* crop to the image by clamping its position while
    /// preserving its size. `clampedToImage` intersects, which is right for
    /// drawing and resizing but destructive for a move: a crop nudged past an
    /// edge would be trimmed, and the trimmed rectangle — not the original —
    /// would carry into the next event, so returning the cursor could not
    /// restore the lost width or height. Combined with an anchor-relative move
    /// (see `pointerDragged`), clamping the translation keeps a move fully
    /// reversible. Non-crop shapes translate freely: an arrow may run off an edge
    /// because it is drawn, not used to select pixels.
    private func clampedMove(_ annotation: Annotation) -> Annotation {
        guard case .crop(let rect) = annotation.shape else { return annotation }
        let r = rect.standardized
        let maxX = max(0, CGFloat(baseImage.width) - r.width)
        let maxY = max(0, CGFloat(baseImage.height) - r.height)
        var result = annotation
        result.shape = .crop(rect: CGRect(x: min(max(0, r.minX), maxX),
                                          y: min(max(0, r.minY), maxY),
                                          width: r.width, height: r.height))
        return result
    }

    private func isNonDegenerate(_ annotation: Annotation) -> Bool {
        switch annotation.shape {
        case .rectangle(let rect), .ellipse(let rect), .crop(let rect),
             .blur(let rect, _), .pixelate(let rect, _):
            return rect.width > 3 && rect.height > 3
        case .line(let s, let e), .arrow(let s, let e):
            return hypot(e.x - s.x, e.y - s.y) > 3
        case .freehand(let points), .highlighter(let points):
            return points.count > 1
        case .text, .step:
            return true   // click-placed (Task 7), never validated through drafting
        }
    }

    private func commitGestureIfChanged() {
        guard let before = gestureStartState else { return }
        gestureStartState = nil
        if before != annotations {
            commitHistory(before)
            refreshHistoryFlags()
        }
    }

    /// Re-reads the toolbar from whatever is selected. Undo/redo replace the document
    /// wholesale, and without this the inspector keeps describing the state that was
    /// just undone.
    private func syncInspectorToSelection() {
        if let selected = selectedAnnotation { syncInspector(to: selected) }
    }

    private func clampSelection() {
        if let id = selectedID, !annotations.contains(where: { $0.id == id }) {
            selectedID = nil
        }
    }

    private func refreshHistoryFlags() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }
}
