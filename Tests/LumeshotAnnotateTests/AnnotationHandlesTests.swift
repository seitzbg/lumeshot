import Testing
import CoreGraphics
@testable import LumeshotAnnotate

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

    @Test func cropTextAndEffectRectsHaveEightBoxHandles() {
        let r = CGRect(x: 0, y: 0, width: 100, height: 40)
        for shape in [AnnotationShape.crop(rect: r),
                      .blur(rect: r, radius: 8),
                      .pixelate(rect: r, scale: 12),
                      .text(rect: r, string: "x", fontSize: 20)] {
            let a = ann(shape)
            let handles = Dictionary(uniqueKeysWithValues: a.handles().map { ($0.kind, $0.point) })
            #expect(handles.count == 8)
            #expect(handles[.topLeft] == CGPoint(x: 0, y: 0))
            #expect(handles[.bottomRight] == CGPoint(x: 100, y: 40))
        }
    }

    @Test func highlighterAndStepHaveNoHandles() {
        #expect(ann(.highlighter(points: [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5)])).handles().isEmpty)
        #expect(ann(.step(center: CGPoint(x: 5, y: 5), number: 1)).handles().isEmpty)
    }

    @Test func movedShiftsHighlighterPointsAndStepCenter() {
        let d = CGVector(dx: 10, dy: -5)
        let hi = ann(.highlighter(points: [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 4)])).moved(by: d)
        if case .highlighter(let points) = hi.shape {
            #expect(points == [CGPoint(x: 10, y: -5), CGPoint(x: 14, y: -1)])
        } else { Issue.record("expected highlighter") }
        let st = ann(.step(center: CGPoint(x: 20, y: 20), number: 7)).moved(by: d)
        if case .step(let center, let number) = st.shape {
            #expect(center == CGPoint(x: 30, y: 15)); #expect(number == 7)
        } else { Issue.record("expected step") }
    }

    @Test func movedPreservesEffectAndTextAssociatedValues() {
        let blur = ann(.blur(rect: CGRect(x: 0, y: 0, width: 10, height: 10), radius: 8)).moved(by: CGVector(dx: 5, dy: 5))
        if case .blur(let rect, let radius) = blur.shape {
            #expect(rect == CGRect(x: 5, y: 5, width: 10, height: 10)); #expect(radius == 8)
        } else { Issue.record("expected blur") }
        let text = ann(.text(rect: CGRect(x: 0, y: 0, width: 10, height: 10), string: "hi", fontSize: 18)).moved(by: CGVector(dx: 1, dy: 2))
        if case .text(let rect, let string, let fontSize) = text.shape {
            #expect(rect == CGRect(x: 1, y: 2, width: 10, height: 10)); #expect(string == "hi"); #expect(fontSize == 18)
        } else { Issue.record("expected text") }
    }

    @Test func resizedReshapesCropAndPreservesEffectValues() {
        let resized = ann(.pixelate(rect: CGRect(x: 0, y: 0, width: 100, height: 40), scale: 12))
            .resized(handle: .topLeft, to: CGPoint(x: 20, y: 10))
        if case .pixelate(let rect, let scale) = resized.shape {
            #expect(rect == CGRect(x: 20, y: 10, width: 80, height: 30)); #expect(scale == 12)
        } else { Issue.record("expected pixelate") }
    }

    @Test func resizedLeavesHighlighterAndStepUnchanged() {
        let hi = ann(.highlighter(points: [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5)]))
        #expect(hi.resized(handle: .topLeft, to: CGPoint(x: 9, y: 9)) == hi)
        let st = ann(.step(center: CGPoint(x: 5, y: 5), number: 1))
        #expect(st.resized(handle: .bottomRight, to: CGPoint(x: 9, y: 9)) == st)
    }

    @Test func movedTranslatesEllipseAndArrow() {
        let d = CGVector(dx: 4, dy: 7)
        let ell = ann(.ellipse(rect: CGRect(x: 0, y: 0, width: 10, height: 20))).moved(by: d)
        #expect(ell.bounds == CGRect(x: 4, y: 7, width: 10, height: 20))
        let arrow = ann(.arrow(start: CGPoint(x: 1, y: 1), end: CGPoint(x: 5, y: 9))).moved(by: d)
        if case .arrow(let s, let e) = arrow.shape {
            #expect(s == CGPoint(x: 5, y: 8)); #expect(e == CGPoint(x: 9, y: 16))
        } else { Issue.record("expected arrow") }
    }

    @Test func resizedReshapesEllipseAndMovesArrowEndpoint() {
        let ell = ann(.ellipse(rect: CGRect(x: 0, y: 0, width: 100, height: 40)))
            .resized(handle: .bottomRight, to: CGPoint(x: 60, y: 20))
        #expect(ell.bounds == CGRect(x: 0, y: 0, width: 60, height: 20))
        let arrow = ann(.arrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 10)))
            .resized(handle: .start, to: CGPoint(x: -5, y: -5))
        if case .arrow(let s, let e) = arrow.shape {
            #expect(s == CGPoint(x: -5, y: -5)); #expect(e == CGPoint(x: 10, y: 10))
        } else { Issue.record("expected arrow") }
    }

    @Test func resizedBoxViaEdgeHandleMovesOnlyThatEdge() {
        let a = ann(.rectangle(rect: CGRect(x: 0, y: 0, width: 100, height: 40)))
        let right = a.resized(handle: .right, to: CGPoint(x: 130, y: 999))
        #expect(right.bounds == CGRect(x: 0, y: 0, width: 130, height: 40))   // only maxX moves
        let bottom = a.resized(handle: .bottom, to: CGPoint(x: 999, y: 10))
        #expect(bottom.bounds == CGRect(x: 0, y: 0, width: 100, height: 10))  // only maxY moves
    }

    @Test func resizedFreehandReturnsSelfUnchanged() {
        let a = ann(.freehand(points: [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5)]))
        let r = a.resized(handle: .topLeft, to: CGPoint(x: 99, y: 99))
        #expect(r == a)
    }

    @Test func handleAtBreaksTiesByFirstNearest() {
        let a = ann(.rectangle(rect: CGRect(x: 0, y: 0, width: 4, height: 4)))
        // Center (2,2) sits an equal 2.0 from all four EDGE handles (and 2.83 from the
        // corners); the strict-`<` tie-break keeps the first in-tolerance nearest, `.top`.
        #expect(a.handle(at: CGPoint(x: 2, y: 2), tolerance: 6) == .top)
    }
}
