import CoreGraphics

/// A draggable grip. Box shapes expose the eight corner/edge handles; line and
/// arrow expose their two endpoints; freehand exposes none in v1 (move-only).
public enum HandleKind: Sendable, Equatable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    case start, end
}

public struct Handle: Sendable, Equatable {
    public let kind: HandleKind
    public let point: CGPoint
    public init(kind: HandleKind, point: CGPoint) {
        self.kind = kind
        self.point = point
    }
}

public extension Annotation {
    func handles() -> [Handle] {
        switch shape {
        case .rectangle(let rect), .ellipse(let rect), .crop(let rect),
             .text(let rect, _, _), .blur(let rect, _), .pixelate(let rect, _):
            let r = rect.standardized
            return [
                Handle(kind: .topLeft, point: CGPoint(x: r.minX, y: r.minY)),
                Handle(kind: .top, point: CGPoint(x: r.midX, y: r.minY)),
                Handle(kind: .topRight, point: CGPoint(x: r.maxX, y: r.minY)),
                Handle(kind: .right, point: CGPoint(x: r.maxX, y: r.midY)),
                Handle(kind: .bottomRight, point: CGPoint(x: r.maxX, y: r.maxY)),
                Handle(kind: .bottom, point: CGPoint(x: r.midX, y: r.maxY)),
                Handle(kind: .bottomLeft, point: CGPoint(x: r.minX, y: r.maxY)),
                Handle(kind: .left, point: CGPoint(x: r.minX, y: r.midY)),
            ]
        case .line(let start, let end), .arrow(let start, let end):
            return [Handle(kind: .start, point: start), Handle(kind: .end, point: end)]
        case .freehand, .highlighter, .step:
            return []
        }
    }

    /// The handle whose grip is nearest `point` within `tolerance`, if any.
    func handle(at point: CGPoint, tolerance: CGFloat) -> HandleKind? {
        var best: (kind: HandleKind, dist: CGFloat)?
        for h in handles() {
            let d = hypot(point.x - h.point.x, point.y - h.point.y)
            if d <= tolerance, best == nil || d < best!.dist { best = (h.kind, d) }
        }
        return best?.kind
    }

    /// Translates the whole shape by `delta`, preserving non-geometry values.
    func moved(by delta: CGVector) -> Annotation {
        var copy = self
        switch shape {
        case .rectangle(let rect):
            copy.shape = .rectangle(rect: rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case .ellipse(let rect):
            copy.shape = .ellipse(rect: rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case .line(let s, let e):
            copy.shape = .line(start: s.moved(by: delta), end: e.moved(by: delta))
        case .arrow(let s, let e):
            copy.shape = .arrow(start: s.moved(by: delta), end: e.moved(by: delta))
        case .freehand(let points):
            copy.shape = .freehand(points: points.map { $0.moved(by: delta) })
        case .crop(let rect):
            copy.shape = .crop(rect: rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case .text(let rect, let string, let fontSize):
            copy.shape = .text(rect: rect.offsetBy(dx: delta.dx, dy: delta.dy), string: string, fontSize: fontSize)
        case .blur(let rect, let radius):
            copy.shape = .blur(rect: rect.offsetBy(dx: delta.dx, dy: delta.dy), radius: radius)
        case .pixelate(let rect, let scale):
            copy.shape = .pixelate(rect: rect.offsetBy(dx: delta.dx, dy: delta.dy), scale: scale)
        case .highlighter(let points):
            copy.shape = .highlighter(points: points.map { $0.moved(by: delta) })
        case .step(let center, let number):
            copy.shape = .step(center: center.moved(by: delta), number: number)
        }
        return copy
    }

    /// Returns a copy with `handle` dragged to `point`. Box shapes (incl. crop/
    /// text/blur/pixelate) reshape the rect; line/arrow move the grabbed endpoint;
    /// freehand/highlighter/step are unchanged (move-only).
    func resized(handle: HandleKind, to point: CGPoint) -> Annotation {
        var copy = self
        switch shape {
        case .rectangle(let rect):
            copy.shape = .rectangle(rect: rect.standardized.resized(handle: handle, to: point))
        case .ellipse(let rect):
            copy.shape = .ellipse(rect: rect.standardized.resized(handle: handle, to: point))
        case .line(let s, let e):
            copy.shape = .line(start: handle == .start ? point : s, end: handle == .end ? point : e)
        case .arrow(let s, let e):
            copy.shape = .arrow(start: handle == .start ? point : s, end: handle == .end ? point : e)
        case .crop(let rect):
            copy.shape = .crop(rect: rect.standardized.resized(handle: handle, to: point))
        case .text(let rect, let string, let fontSize):
            copy.shape = .text(rect: rect.standardized.resized(handle: handle, to: point), string: string, fontSize: fontSize)
        case .blur(let rect, let radius):
            copy.shape = .blur(rect: rect.standardized.resized(handle: handle, to: point), radius: radius)
        case .pixelate(let rect, let scale):
            copy.shape = .pixelate(rect: rect.standardized.resized(handle: handle, to: point), scale: scale)
        case .freehand, .highlighter, .step:
            break
        }
        return copy
    }
}

private extension CGPoint {
    func moved(by d: CGVector) -> CGPoint { CGPoint(x: x + d.dx, y: y + d.dy) }
}

private extension CGRect {
    /// Reshapes by dragging one handle to `p`; result is re-normalized.
    func resized(handle: HandleKind, to p: CGPoint) -> CGRect {
        var minX = self.minX, minY = self.minY, maxX = self.maxX, maxY = self.maxY
        switch handle {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        case .start, .end: break
        }
        return CGRect(x: Swift.min(minX, maxX), y: Swift.min(minY, maxY),
                      width: Swift.abs(maxX - minX), height: Swift.abs(maxY - minY))
    }
}
