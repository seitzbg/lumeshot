import CoreGraphics

public extension Annotation {
    /// Axis-aligned bounding box in image-pixel space.
    var bounds: CGRect {
        switch shape {
        case .rectangle(let rect), .ellipse(let rect), .crop(let rect),
             .blur(let rect, _), .pixelate(let rect, _), .text(let rect, _, _):
            return rect.standardized
        case .line(let start, let end), .arrow(let start, let end):
            return CGRect(spanning: start, end)
        case .freehand(let points), .highlighter(let points):
            guard let first = points.first else { return .zero }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for p in points.dropFirst() {
                minX = Swift.min(minX, p.x); minY = Swift.min(minY, p.y)
                maxX = Swift.max(maxX, p.x); maxY = Swift.max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .step(let center, _):
            let r = AnnotationDefaults.stepRadius
            return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        }
    }

    /// Whether `point` selects this annotation. Box shapes (incl. crop/text/blur/
    /// pixelate) use inflated bounds; ellipse uses the normalized-radius test;
    /// line/arrow and freehand use point-to-segment distance; highlighter widens
    /// the band to its min stroke width; step uses its badge radius.
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch shape {
        case .rectangle(let rect), .crop(let rect), .blur(let rect, _),
             .pixelate(let rect, _), .text(let rect, _, _):
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
                return points.first.map { distanceFromPoint(point, toSegmentA: $0, b: $0) <= tolerance } ?? false
            }
            for i in 0..<(points.count - 1) {
                if distanceFromPoint(point, toSegmentA: points[i], b: points[i + 1]) <= tolerance {
                    return true
                }
            }
            return false
        case .highlighter(let points):
            let band = Swift.max(tolerance, AnnotationDefaults.highlighterMinWidth / 2)
            guard points.count > 1 else {
                return points.first.map { hypot(point.x - $0.x, point.y - $0.y) <= band } ?? false
            }
            for i in 0..<(points.count - 1) {
                if distanceFromPoint(point, toSegmentA: points[i], b: points[i + 1]) <= band {
                    return true
                }
            }
            return false
        case .step(let center, _):
            return hypot(point.x - center.x, point.y - center.y) <= AnnotationDefaults.stepRadius + tolerance
        }
    }
}
