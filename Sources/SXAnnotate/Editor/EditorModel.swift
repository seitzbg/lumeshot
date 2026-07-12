import CoreGraphics
import Combine

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
    @Published public private(set) var selectedID: Annotation.ID?
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false

    public let hitTolerance: CGFloat = 8
    public let handleTolerance: CGFloat = 9

    private var history = AnnotationHistory()

    // Per-gesture transient state.
    private var draft: Annotation?           // shape being drawn
    private var drawAnchor: CGPoint?         // draw start point
    private var activeHandle: HandleKind?    // resize in progress
    private var lastDragPoint: CGPoint?      // move in progress
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
        } else if let handle = activeHandle, let id = selectedID,
                  let index = annotations.firstIndex(where: { $0.id == id }) {
            annotations[index] = annotations[index].resized(handle: handle, to: point)
        } else if let last = lastDragPoint, let id = selectedID,
                  let index = annotations.firstIndex(where: { $0.id == id }) {
            let delta = CGVector(dx: point.x - last.x, dy: point.y - last.y)
            annotations[index] = annotations[index].moved(by: delta)
            lastDragPoint = point
        }
    }

    public func pointerUp(at point: CGPoint) {
        if draft != nil, let anchor = drawAnchor {
            let finished = updatedDraft(anchor: anchor, to: point)
            if isNonDegenerate(finished) {
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
        lastDragPoint = nil
    }

    // MARK: Commands

    public func deleteSelected() {
        guard let id = selectedID, let target = annotations.first(where: { $0.id == id }) else { return }
        history.commit(annotations)
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
        guard let previous = history.undo(current: annotations) else { return }
        annotations = previous
        clampSelection()
        refreshHistoryFlags()
    }

    public func redo() {
        guard let next = history.redo(current: annotations) else { return }
        annotations = next
        clampSelection()
        refreshHistoryFlags()
    }

    public func flatten() -> CGImage? {
        AnnotationRenderer.flatten(base: baseImage, annotations: annotations)
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
        case .text(let rect, let str, _): updated = .text(rect: rect, string: str, fontSize: textFontSize)
        default:                        updated = nil
        }
        guard let newShape = updated else { return }
        history.commit(annotations)
        annotations[index].shape = newShape
        refreshHistoryFlags()
    }

    /// Places an empty text box at `point`, enters edit mode and selects it. The
    /// placement is committed to history only when non-empty text is finalized
    /// (see `endTextEditing`), so abandoning an empty box leaves no undo step.
    public func beginTextEditing(at point: CGPoint) {
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
        if case .text(_, let string, _) = annotations[index].shape, string.isEmpty {
            annotations.remove(at: index)
            if selectedID == id { selectedID = nil }
            textEditStartState = nil
            return
        }
        if let before = textEditStartState {
            history.commit(before)
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
            return
        }
        // Otherwise pick the topmost annotation under the point.
        if let hit = annotations.last(where: { $0.hitTest(point, tolerance: hitTolerance) }) {
            selectedID = hit.id
            lastDragPoint = point
        } else {
            selectedID = nil
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
        history.commit(annotations)
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
        switch activeTool {
        case .rectangle: current.shape = .rectangle(rect: CGRect(spanning: anchor, point))
        case .ellipse:   current.shape = .ellipse(rect: CGRect(spanning: anchor, point))
        case .line:      current.shape = .line(start: anchor, end: point)
        case .arrow:     current.shape = .arrow(start: anchor, end: point)
        case .freehand:
            if case .freehand(var points) = current.shape {
                points.append(point)
                current.shape = .freehand(points: points)
            }
        // M3b drag tools:
        case .crop:      current.shape = .crop(rect: CGRect(spanning: anchor, point))
        case .blur:      current.shape = .blur(rect: CGRect(spanning: anchor, point), radius: blurRadius)
        case .pixelate:  current.shape = .pixelate(rect: CGRect(spanning: anchor, point), scale: pixelScale)
        case .highlighter:
            if case .highlighter(var points) = current.shape {
                points.append(point)
                current.shape = .highlighter(points: points)
            }
        case .text, .step, .select:
            break
        }
        return current
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
            history.commit(before)
            refreshHistoryFlags()
        }
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
