import CoreGraphics

public extension Annotation {
    /// Axis-aligned bounding box in image-pixel space.
    var bounds: CGRect {
        switch shape {
        case .rectangle(let rect), .ellipse(let rect):
            return rect.standardized
        case .line(let start, let end), .arrow(let start, let end):
            return CGRect(spanning: start, end)
        case .freehand(let points):
            guard let first = points.first else { return .zero }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for p in points.dropFirst() {
                minX = Swift.min(minX, p.x); minY = Swift.min(minY, p.y)
                maxX = Swift.max(maxX, p.x); maxY = Swift.max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        default:
            return .zero        // M3b: real arms added in Task 2
        }
    }

    /// Whether `point` selects this annotation. Box shapes use inflated bounds
    /// (matching ShareX); ellipse uses the normalized-radius test; line/arrow and
    /// freehand use point-to-segment distance.
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch shape {
        case .rectangle(let rect):
            return rect.standardized.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .ellipse(let rect):
            let r = rect.standardized
            let rx = r.width / 2 + tolerance, ry = r.height / 2 + tolerance
            guard rx > 0, ry > 0 else { return false }
            let cx = r.midX, cy = r.midY
            let nx = (point.x - cx) / rx, ny = (point.y - cy) / ry
            return nx * nx + ny * ny <= 1
        case .line(let start, let end), .arrow(let start, let end):
            return distanceFromPoint(point, toSegmentA: start, b: end) <= tolerance
        case .freehand(let points):
            guard points.count > 1 else {
                return points.first.map { hypot(point.x - $0.x, point.y - $0.y) <= tolerance } ?? false
            }
            for i in 0..<(points.count - 1) {
                if distanceFromPoint(point, toSegmentA: points[i], b: points[i + 1]) <= tolerance {
                    return true
                }
            }
            return false
        default:
            return false        // M3b: real arms added in Task 2
        }
    }
}
