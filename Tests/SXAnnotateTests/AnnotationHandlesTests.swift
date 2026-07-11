import Testing
import CoreGraphics
@testable import SXAnnotate

@Suite struct AnnotationHandlesTests {
    private func ann(_ shape: AnnotationShape) -> Annotation {
        Annotation(id: .init(), shape: shape, style: AnnotationStyle())
    }

    @Test func boxHasEightHandlesAtCornersAndEdges() {
        let a = ann(.rectangle(rect: CGRect(x: 0, y: 0, width: 100, height: 40)))
        let handles = Dictionary(uniqueKeysWithValues: a.handles().map { ($0.kind, $0.point) })
        #expect(handles[.topLeft] == CGPoint(x: 0, y: 0))
        #expect(handles[.top] == CGPoint(x: 50, y: 0))
        #expect(handles[.bottomRight] == CGPoint(x: 100, y: 40))
        #expect(handles[.left] == CGPoint(x: 0, y: 20))
        #expect(handles.count == 8)
    }

    @Test func lineHasStartAndEndHandles() {
        let a = ann(.line(start: CGPoint(x: 3, y: 4), end: CGPoint(x: 30, y: 40)))
        let kinds = Set(a.handles().map(\.kind))
        #expect(kinds == [.start, .end])
    }

    @Test func freehandHasNoHandles() {
        let a = ann(.freehand(points: [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5)]))
        #expect(a.handles().isEmpty)
    }

    @Test func handleAtFindsNearestWithinTolerance() {
        let a = ann(.rectangle(rect: CGRect(x: 0, y: 0, width: 100, height: 40)))
        #expect(a.handle(at: CGPoint(x: 2, y: 2), tolerance: 6) == .topLeft)
        #expect(a.handle(at: CGPoint(x: 50, y: 50), tolerance: 6) == nil)
    }

    @Test func movedTranslatesEveryShape() {
        let d = CGVector(dx: 10, dy: -5)
        let rect = ann(.rectangle(rect: CGRect(x: 1, y: 2, width: 3, height: 4))).moved(by: d)
        #expect(rect.bounds == CGRect(x: 11, y: -3, width: 3, height: 4))
        let line = ann(.line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 2, y: 2))).moved(by: d)
        if case .line(let s, let e) = line.shape {
            #expect(s == CGPoint(x: 10, y: -5)); #expect(e == CGPoint(x: 12, y: -3))
        } else { Issue.record("expected line") }
    }

    @Test func resizedBoxMovesTheGrabbedCorner() {
        let a = ann(.rectangle(rect: CGRect(x: 0, y: 0, width: 100, height: 40)))
        let resized = a.resized(handle: .topLeft, to: CGPoint(x: 20, y: 10))
        #expect(resized.bounds == CGRect(x: 20, y: 10, width: 80, height: 30))
    }

    @Test func resizedLineMovesTheGrabbedEndpoint() {
        let a = ann(.line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0)))
        let resized = a.resized(handle: .end, to: CGPoint(x: 50, y: 50))
        if case .line(let s, let e) = resized.shape {
            #expect(s == CGPoint(x: 0, y: 0)); #expect(e == CGPoint(x: 50, y: 50))
        } else { Issue.record("expected line") }
    }
}
