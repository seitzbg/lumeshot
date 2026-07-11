/// Value-snapshot undo/redo. Because `[Annotation]` is a value type, a copy is a
/// deep copy — no cloning machinery needed. Call `commit(current)` immediately
/// *before* mutating; `undo`/`redo` swap the caller's `current` through the stacks.
public struct AnnotationHistory: Sendable {
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private let limit: Int

    public init(limit: Int = 50) {
        self.limit = Swift.max(1, limit)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Snapshots the pre-mutation state and invalidates the redo history.
    public mutating func commit(_ state: [Annotation]) {
        undoStack.append(state)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    public mutating func undo(current: [Annotation]) -> [Annotation]? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    public mutating func redo(current: [Annotation]) -> [Annotation]? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}
