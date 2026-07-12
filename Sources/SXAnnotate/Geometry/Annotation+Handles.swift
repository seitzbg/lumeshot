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
        case .rectangle(let rect), .ellipse(let rect):
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
        case .freehand:
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

    /// Translates the whole shape by `delta`.
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
        }
        return copy
    }

    /// Returns a copy with `handle` dragged to `point`. Box handles reshape the
    /// rect; `.start`/`.end` move the grabbed endpoint. Freehand is unchanged.
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
        case .freehand:
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
