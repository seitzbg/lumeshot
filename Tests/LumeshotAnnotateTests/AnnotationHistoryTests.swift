import Testing
import CoreGraphics
@testable import LumeshotAnnotate

@Suite struct AnnotationHistoryTests {
    private func doc(_ n: Int) -> [Annotation] {
        (0..<n).map { _ in Annotation(id: .init(),
                                      shape: .rectangle(rect: .zero),
                                      style: AnnotationStyle()) }
    }

    @Test func freshHistoryCannotUndoOrRedo() {
        let h = AnnotationHistory()
        #expect(!h.canUndo); #expect(!h.canRedo)
    }

    @Test func undoReturnsThePreCommitState() {
        var h = AnnotationHistory()
        let before = doc(1), after = doc(2)
        h.commit(before)            // snapshot state before adding the 2nd shape
        #expect(h.canUndo)
        let restored = h.undo(current: after)
        #expect(restored?.count == 1)
        #expect(h.canRedo)
    }

    @Test func redoReappliesTheUndoneState() {
        var h = AnnotationHistory()
        let before = doc(1), after = doc(2)
        h.commit(before)
        _ = h.undo(current: after)
        let redone = h.redo(current: before)
        #expect(redone?.count == 2)
        #expect(h.canUndo)
        #expect(!h.canRedo)
    }

    @Test func commitClearsRedo() {
        var h = AnnotationHistory()
        h.commit(doc(1))
        _ = h.undo(current: doc(2))
        #expect(h.canRedo)
        h.commit(doc(2))            // a new edit invalidates redo
        #expect(!h.canRedo)
    }

    @Test func undoOnEmptyReturnsNil() {
        var h = AnnotationHistory()
        #expect(h.undo(current: doc(1)) == nil)
    }

    @Test func stackIsBoundedByLimit() {
        var h = AnnotationHistory(limit: 3)
        for i in 0..<10 { h.commit(doc(i + 1)) }
        var count = 0
        var current = doc(99)
        while let prev = h.undo(current: current) { current = prev; count += 1 }
        #expect(count == 3)         // only the last 3 commits survive
    }

    @Test func redoOnEmptyReturnsNil() {
        var h = AnnotationHistory()
        #expect(h.redo(current: doc(1)) == nil)
        #expect(!h.canRedo)
    }

    @Test func limitBelowOneClampsToOne() {
        var h = AnnotationHistory(limit: 0)     // clamped up to 1
        h.commit(doc(1))
        h.commit(doc(2))                        // only the most recent survives
        var count = 0
        var current = doc(3)
        while let prev = h.undo(current: current) { current = prev; count += 1 }
        #expect(count == 1)
    }
}
