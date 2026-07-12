import CoreGraphics

public extension CGRect {
    /// A normalized (non-negative width/height) rect spanning two corner points.
    init(spanning a: CGPoint, _ b: CGPoint) {
        self.init(x: Swift.min(a.x, b.x), y: Swift.min(a.y, b.y),
                  width: Swift.abs(a.x - b.x), height: Swift.abs(a.y - b.y))
    }
}

/// Shortest distance from `p` to the finite segment a→b.
public func distanceFromPoint(_ p: CGPoint, toSegmentA a: CGPoint, b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    if lengthSquared == 0 { return hypot(p.x - a.x, p.y - a.y) }
    // Projection parameter of p onto the line, clamped to the segment.
    var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
    t = Swift.max(0, Swift.min(1, t))
    let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
    return hypot(p.x - proj.x, p.y - proj.y)
}
