import Testing
import CoreGraphics
import Foundation
@testable import SXAnnotate

@Suite struct AnnotationCodableTests {
    private func roundTrip(_ a: Annotation) throws -> Annotation {
        let data = try JSONEncoder().encode(a)
        return try JSONDecoder().decode(Annotation.self, from: data)
    }

    @Test func rectangleRoundTrips() throws {
        let a = Annotation(id: UUID(),
                           shape: .rectangle(rect: CGRect(x: 1, y: 2, width: 30, height: 40)),
                           style: AnnotationStyle(strokeColor: .red, strokeWidth: 4, fillColor: .clear))
        #expect(try roundTrip(a) == a)
    }

    @Test func allShapesRoundTrip() throws {
        let shapes: [AnnotationShape] = [
            .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10)),
            .ellipse(rect: CGRect(x: 5, y: 5, width: 20, height: 8)),
            .line(start: CGPoint(x: 1, y: 1), end: CGPoint(x: 9, y: 9)),
            .arrow(start: CGPoint(x: 2, y: 3), end: CGPoint(x: 40, y: 5)),
            .freehand(points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 1)]),
        ]
        for shape in shapes {
            let a = Annotation(id: UUID(), shape: shape, style: AnnotationStyle())
            #expect(try roundTrip(a) == a)
        }
    }

    @Test func defaultStyleIsRedStrokeNoFill() {
        let s = AnnotationStyle()
        #expect(s.strokeColor == .red)
        #expect(s.strokeWidth == 4)
        #expect(s.fillColor == .clear)
    }
}
