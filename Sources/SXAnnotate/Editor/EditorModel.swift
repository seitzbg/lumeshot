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
        if let draft, let anchor = drawAnchor {
            let finished = updatedDraft(anchor: anchor, to: point)
            if isNonDegenerate(finished) {
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
        guard let id = selectedID, annotations.contains(where: { $0.id == id }) else { return }
        history.commit(annotations)
        annotations.removeAll { $0.id == id }
        selectedID = nil
        refreshHistoryFlags()
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

    private func shape(for tool: EditorTool, anchor: CGPoint, to point: CGPoint) -> AnnotationShape {
        switch tool {
        case .rectangle: return .rectangle(rect: CGRect(spanning: anchor, point))
        case .ellipse:   return .ellipse(rect: CGRect(spanning: anchor, point))
        case .line:      return .line(start: anchor, end: point)
        case .arrow:     return .arrow(start: anchor, end: point)
        case .freehand:  return .freehand(points: [anchor])
        case .select:    return .rectangle(rect: CGRect(spanning: anchor, point))  // unreachable
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
        case .select:
            break
        }
        return current
    }

    private func isNonDegenerate(_ annotation: Annotation) -> Bool {
        switch annotation.shape {
        case .rectangle(let rect), .ellipse(let rect):
            return rect.width > 3 && rect.height > 3
        case .line(let s, let e), .arrow(let s, let e):
            return hypot(e.x - s.x, e.y - s.y) > 3
        case .freehand(let points):
            return points.count > 1
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
