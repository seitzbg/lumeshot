import Testing
import CoreGraphics
import Foundation
@testable import LumeshotAnnotate

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

    @Test func m3bShapesRoundTrip() throws {
        let shapes: [AnnotationShape] = [
            .crop(rect: CGRect(x: 2, y: 3, width: 40, height: 30)),
            .text(rect: CGRect(x: 1, y: 1, width: 80, height: 24), string: "Hello", fontSize: 24),
            .highlighter(points: [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 6), CGPoint(x: 9, y: 2)]),
            .blur(rect: CGRect(x: 4, y: 4, width: 20, height: 20), radius: 8),
            .pixelate(rect: CGRect(x: 6, y: 6, width: 18, height: 12), scale: 12),
            .step(center: CGPoint(x: 15, y: 20), number: 3),
        ]
        for shape in shapes {
            let a = Annotation(id: UUID(), shape: shape, style: AnnotationStyle())
            #expect(try roundTrip(a) == a)
        }
    }
}
