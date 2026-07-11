# M3a — Editor Core & Vector Shapes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an "annotate before share" image editor to sharex-mac with a non-destructive document model and the five vector-shape tools (rectangle, ellipse, line, arrow, freehand), select/move/resize, unlimited undo/redo, and integration into the after-capture pipeline.

**Architecture:** A new dependency-light `SXAnnotate` library target holds the pure model (value-type `Annotation` + `AnnotationShape` enum), geometry (bounds, hit-testing, handles, move/resize), value-snapshot undo history, a single `AnnotationRenderer` used for both live display and export, and the `@MainActor` `EditorModel` interaction state machine — all unit-tested with swift-testing. The interactive shell (an AppKit `NSView` canvas, a SwiftUI toolbar/inspector window, and the pipeline gate) lives in `SXApp` and is smoke-tested, matching the existing executable-target convention. The editor inserts as an injected `EditorPresenting` gate at the top of `CaptureCoordinator.deliver`; when enabled it transforms the captured `CGImage` before the existing save→clipboard→upload chain runs, so the local-first invariant is preserved for the edited artifact.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM (tools 6.0), macOS 15+, AppKit + CoreGraphics for the canvas, SwiftUI (via `NSHostingController`) for chrome, swift-testing for tests. No new external dependencies.

## Global Constraints

*Every task's requirements implicitly include this section. Values are copied verbatim from the approved spec `docs/superpowers/specs/2026-07-10-sharex-mac-design.md` and the project's standing rules.*

- **No new runtime dependencies.** SXAnnotate imports only `Foundation` + `CoreGraphics` (plus `Combine` for `ObservableObject`); the app stays dependency-free (spec §2).
- **Swift 6 strict concurrency.** Model types are `Sendable` value types; mutable editor state lives in one `@MainActor` class. No data races, no `@unchecked` without justification.
- **Non-destructive document** (spec §3.2): base image + ordered annotation list; export flattens via CoreGraphics. The base image is never mutated in M3a.
- **Local-first invariant** (spec §2): every *finalized* capture is written to disk before any upload. With annotate-mode on, disk save happens when the user finalizes the edit; cancelling the editor before finalizing is an intentional discard (nothing was saved or uploaded).
- **Fail-loud** (spec §5): surface errors via `AppLog.log` and/or a notification; never silently catch-and-drop.
- **Coordinate convention (binding, applies to every geometry/render task):** annotation coordinates are in **image-pixel space, top-left origin, y increasing downward**. Renderers and views apply the flip/scale via the CTM or `CanvasGeometry`; annotation math never bakes in a flip.
- **v1 toolset only** (spec §3.2, §7): M3a ships select/move, rectangle, ellipse, line, arrow, freehand. Deliberately deferred as post-v1 within M3a: rotation, multiple arrow styles, curved segments, shadows, corner radius, border styles, per-node freehand resize. (Crop, text, highlighter, blur, pixelate, step-number badges are M3b.) Do not add tools, styles, or options beyond this list.
- **Test framework:** swift-testing (`import Testing`, `@Test`, `#expect`, `@Suite`) — the project uses zero XCTest. MainActor-isolated suites are `@MainActor @Suite`.
- **Naming/copy rule:** no AI-attribution boilerplate anywhere (commits, docs, comments) — no "Generated with", no "Co-Authored-By".
- **Build/test loop:** `scripts/remote.sh build` and `scripts/remote.sh test` rsync to the Mac and run over SSH; `scripts/remote.sh run` rebuilds+bundles+launches for interactive smoke. `build`/`test` do NOT re-bundle the `.app`.

## File Structure

New library target **`SXAnnotate`** (`Sources/SXAnnotate/`):
- `Model/RGBAColor.swift` — Codable RGBA color (0…1) + `cgColor` bridge.
- `Model/AnnotationStyle.swift` — stroke color/width + fill color.
- `Model/AnnotationShape.swift` — the closed geometry enum (rectangle, ellipse, line, arrow, freehand).
- `Model/Annotation.swift` — `Annotation` value type (id + shape + style).
- `Model/EditorTool.swift` — the tool enum.
- `Geometry/Annotation+Geometry.swift` — `bounds`, `hitTest`.
- `Geometry/Annotation+Handles.swift` — `HandleKind`, `Handle`, `handles()`, `handle(at:tolerance:)`, `moved(by:)`, `resized(handle:to:)`.
- `Geometry/GeometryHelpers.swift` — `CGRect(spanning:_:)`, point-to-segment distance.
- `History/AnnotationHistory.swift` — value-snapshot undo/redo stacks.
- `Rendering/AnnotationRenderer.swift` — `drawAnnotations(_:in:)`, `flatten(base:annotations:)`.
- `Rendering/CanvasGeometry.swift` — aspect-fit image↔view transform.
- `Editor/EditorModel.swift` — `@MainActor` interaction state machine.

New tests target **`SXAnnotateTests`** (`Tests/SXAnnotateTests/`): one `<Type>Tests.swift` per unit, plus `Fixtures/` for the snapshot golden.

Shell additions in **`SXApp`** (`Sources/SXApp/`):
- `EditorCanvasView.swift` — AppKit `NSView` + `NSViewRepresentable` wrapper.
- `EditorView.swift` — SwiftUI toolbar + canvas + inspector.
- `EditorWindowController.swift` — window host + `EditorPresenting` conformance.

Modified: `Package.swift` (new targets), `Sources/SXCore/AppSettings.swift` (`EditorSettings`), `Sources/SXApp/CaptureCoordinator.swift` (gate), `Sources/SXApp/AppDelegate.swift` (menu + presenter wiring), `docs/porting-map.md`, `README.md`.

---

### Task 1: SXAnnotate target scaffold + core value types

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SXAnnotate/Model/RGBAColor.swift`
- Create: `Sources/SXAnnotate/Model/AnnotationStyle.swift`
- Create: `Sources/SXAnnotate/Model/AnnotationShape.swift`
- Create: `Sources/SXAnnotate/Model/Annotation.swift`
- Create: `Sources/SXAnnotate/Model/EditorTool.swift`
- Test: `Tests/SXAnnotateTests/AnnotationCodableTests.swift`

**Interfaces:**
- Produces: `RGBAColor(r:g:b:a:)` (Doubles 0…1) with `.red`, `.clear`, `var cgColor: CGColor`; `AnnotationStyle(strokeColor:strokeWidth:fillColor:)`; `enum AnnotationShape { case rectangle(rect: CGRect); case ellipse(rect: CGRect); case line(start: CGPoint, end: CGPoint); case arrow(start: CGPoint, end: CGPoint); case freehand(points: [CGPoint]) }`; `struct Annotation { let id: UUID; var shape: AnnotationShape; var style: AnnotationStyle }`; `enum EditorTool: String, CaseIterable { case select, rectangle, ellipse, line, arrow, freehand }`. All `Codable, Sendable, Equatable`; `Annotation` is `Identifiable`.

- [ ] **Step 1: Add the SXAnnotate + SXAnnotateTests targets**

Edit `Package.swift` to this exact content:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sharex-mac",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "SXApp", dependencies: ["SXCore", "SXCapture", "SXUpload", "SXAnnotate"]),
        .target(name: "SXCore"),
        .target(name: "SXCapture", dependencies: ["SXCore"]),
        .target(name: "SXUpload", dependencies: ["SXCore"]),
        .target(name: "SXAnnotate"),
        .testTarget(name: "SXCoreTests", dependencies: ["SXCore"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "SXCaptureTests", dependencies: ["SXCapture"]),
        .testTarget(name: "SXUploadTests", dependencies: ["SXUpload"]),
        .testTarget(name: "SXAnnotateTests", dependencies: ["SXAnnotate"],
                    resources: [.copy("Fixtures")]),
    ]
)
```

- [ ] **Step 2: Write the failing Codable round-trip test**

Create `Tests/SXAnnotateTests/AnnotationCodableTests.swift`:

```swift
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
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `scripts/remote.sh test`
Expected: FAIL — `SXAnnotate` / `Annotation` not found (target does not exist yet).

- [ ] **Step 4: Implement the model types**

Create `Sources/SXAnnotate/Model/RGBAColor.swift`:

```swift
import CoreGraphics

/// An sRGB color with channels in 0…1. Codable/Sendable so it lives in the
/// document model; `cgColor` bridges to CoreGraphics at the render boundary.
public struct RGBAColor: Codable, Sendable, Equatable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// ShareX's default annotation stroke, #ef4444.
    public static let red = RGBAColor(r: 0.937, g: 0.267, b: 0.267, a: 1)
    public static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)

    public var cgColor: CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    public var isClear: Bool { a == 0 }
}
```

Create `Sources/SXAnnotate/Model/AnnotationStyle.swift`:

```swift
/// Shared visual properties every annotation carries. `fillColor == .clear`
/// means stroke-only.
public struct AnnotationStyle: Codable, Sendable, Equatable {
    public var strokeColor: RGBAColor
    public var strokeWidth: Double
    public var fillColor: RGBAColor

    public init(strokeColor: RGBAColor = .red,
                strokeWidth: Double = 4,
                fillColor: RGBAColor = .clear) {
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
        self.fillColor = fillColor
    }
}
```

Create `Sources/SXAnnotate/Model/AnnotationShape.swift`:

```swift
import CoreGraphics

/// The closed set of v1 vector shapes. Box shapes carry their normalized rect;
/// line/arrow carry endpoints; freehand carries its point list. Coordinates are
/// image-pixel space, top-left origin, y-down (see plan Global Constraints).
public enum AnnotationShape: Codable, Sendable, Equatable {
    case rectangle(rect: CGRect)
    case ellipse(rect: CGRect)
    case line(start: CGPoint, end: CGPoint)
    case arrow(start: CGPoint, end: CGPoint)
    case freehand(points: [CGPoint])
}
```

Create `Sources/SXAnnotate/Model/Annotation.swift`:

```swift
import Foundation

/// One item in the non-destructive document. List order is z-order (later = on top).
public struct Annotation: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var shape: AnnotationShape
    public var style: AnnotationStyle

    public init(id: UUID = UUID(), shape: AnnotationShape, style: AnnotationStyle) {
        self.id = id
        self.shape = shape
        self.style = style
    }
}
```

Create `Sources/SXAnnotate/Model/EditorTool.swift`:

```swift
/// The active editor tool. `.select` edits existing annotations; the rest draw.
/// M3b extends this enum (crop, text, highlight, blur, pixelate, step).
public enum EditorTool: String, Codable, Sendable, CaseIterable {
    case select
    case rectangle
    case ellipse
    case line
    case arrow
    case freehand
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `scripts/remote.sh test`
Expected: PASS (all `AnnotationCodableTests`). If pre-existing tests in other targets also run, they must remain green.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/SXAnnotate Tests/SXAnnotateTests
git commit -m "Add SXAnnotate target with core annotation value types"
```

---

### Task 2: Geometry — bounds + hit-testing

**Files:**
- Create: `Sources/SXAnnotate/Geometry/GeometryHelpers.swift`
- Create: `Sources/SXAnnotate/Geometry/Annotation+Geometry.swift`
- Test: `Tests/SXAnnotateTests/AnnotationGeometryTests.swift`

**Interfaces:**
- Consumes: `Annotation`, `AnnotationShape` (Task 1).
- Produces: `extension CGRect { init(spanning a: CGPoint, _ b: CGPoint) }`; `func distanceFromPoint(_ p: CGPoint, toSegmentA a: CGPoint, b: CGPoint) -> CGFloat`; `Annotation.bounds: CGRect`; `Annotation.hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool` (default `tolerance` handled by callers; provide with an explicit parameter).

- [ ] **Step 1: Write the failing tests**

Create `Tests/SXAnnotateTests/AnnotationGeometryTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import SXAnnotate

@Suite struct AnnotationGeometryTests {
    private func ann(_ shape: AnnotationShape) -> Annotation {
        Annotation(id: .init(), shape: shape, style: AnnotationStyle())
    }

    @Test func rectSpanningNormalizesReversedCorners() {
        let r = CGRect(spanning: CGPoint(x: 30, y: 40), CGPoint(x: 10, y: 5))
        #expect(r == CGRect(x: 10, y: 5, width: 20, height: 35))
    }

    @Test func boundsOfBoxIsItsRect() {
        let rect = CGRect(x: 4, y: 6, width: 20, height: 10)
        #expect(ann(.rectangle(rect: rect)).bounds == rect)
        #expect(ann(.ellipse(rect: rect)).bounds == rect)
    }

    @Test func boundsOfLineSpansEndpoints() {
        let b = ann(.line(start: CGPoint(x: 10, y: 2), end: CGPoint(x: 2, y: 9))).bounds
        #expect(b == CGRect(x: 2, y: 2, width: 8, height: 7))
    }

    @Test func boundsOfFreehandSpansAllPoints() {
        let b = ann(.freehand(points: [CGPoint(x: 5, y: 5), CGPoint(x: 1, y: 9), CGPoint(x: 8, y: 3)])).bounds
        #expect(b == CGRect(x: 1, y: 3, width: 7, height: 6))
    }

    @Test func rectangleHitTestUsesInflatedBounds() {
        let a = ann(.rectangle(rect: CGRect(x: 10, y: 10, width: 40, height: 30)))
        #expect(a.hitTest(CGPoint(x: 30, y: 25), tolerance: 8))   // inside
        #expect(a.hitTest(CGPoint(x: 6, y: 25), tolerance: 8))    // within tolerance outside
        #expect(!a.hitTest(CGPoint(x: 0, y: 0), tolerance: 8))    // far away
    }

    @Test func ellipseHitTestRejectsCorner() {
        let a = ann(.ellipse(rect: CGRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(a.hitTest(CGPoint(x: 50, y: 50), tolerance: 5))   // center
        #expect(!a.hitTest(CGPoint(x: 2, y: 2), tolerance: 5))    // corner is outside the ellipse
    }

    @Test func lineHitTestUsesSegmentDistance() {
        let a = ann(.line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0)))
        #expect(a.hitTest(CGPoint(x: 50, y: 3), tolerance: 6))    // near the segment
        #expect(!a.hitTest(CGPoint(x: 50, y: 20), tolerance: 6))  // far from the segment
        #expect(!a.hitTest(CGPoint(x: 150, y: 0), tolerance: 6))  // beyond the endpoint
    }

    @Test func freehandHitTestNearAnySegment() {
        let a = ann(.freehand(points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]))
        #expect(a.hitTest(CGPoint(x: 10, y: 5), tolerance: 4))    // near second segment
        #expect(!a.hitTest(CGPoint(x: 0, y: 10), tolerance: 4))   // interior, not near any segment
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `bounds`, `hitTest`, `CGRect(spanning:_:)` not defined.

- [ ] **Step 3: Implement the geometry helpers and methods**

Create `Sources/SXAnnotate/Geometry/GeometryHelpers.swift`:

```swift
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
```

Create `Sources/SXAnnotate/Geometry/Annotation+Geometry.swift`:

```swift
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
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS (all `AnnotationGeometryTests`).

- [ ] **Step 5: Commit**

```bash
git add Sources/SXAnnotate/Geometry Tests/SXAnnotateTests/AnnotationGeometryTests.swift
git commit -m "Add annotation bounds and hit-testing"
```

---

### Task 3: Handles + move/resize transforms

**Files:**
- Create: `Sources/SXAnnotate/Geometry/Annotation+Handles.swift`
- Test: `Tests/SXAnnotateTests/AnnotationHandlesTests.swift`

**Interfaces:**
- Consumes: `Annotation`, `AnnotationShape`, `CGRect(spanning:_:)` (Tasks 1–2).
- Produces: `enum HandleKind: Sendable, Equatable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, start, end }`; `struct Handle: Sendable, Equatable { let kind: HandleKind; let point: CGPoint }`; `Annotation.handles() -> [Handle]`; `Annotation.handle(at point: CGPoint, tolerance: CGFloat) -> HandleKind?`; `Annotation.moved(by delta: CGVector) -> Annotation`; `Annotation.resized(handle: HandleKind, to point: CGPoint) -> Annotation`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SXAnnotateTests/AnnotationHandlesTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `handles`, `handle(at:)`, `moved(by:)`, `resized(handle:to:)` not defined.

- [ ] **Step 3: Implement handles + transforms**

Create `Sources/SXAnnotate/Geometry/Annotation+Handles.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS (all `AnnotationHandlesTests`).

- [ ] **Step 5: Commit**

```bash
git add Sources/SXAnnotate/Geometry/Annotation+Handles.swift Tests/SXAnnotateTests/AnnotationHandlesTests.swift
git commit -m "Add annotation handles and move/resize transforms"
```

---

### Task 4: Undo/redo history

**Files:**
- Create: `Sources/SXAnnotate/History/AnnotationHistory.swift`
- Test: `Tests/SXAnnotateTests/AnnotationHistoryTests.swift`

**Interfaces:**
- Consumes: `Annotation` (Task 1).
- Produces: `struct AnnotationHistory: Sendable { init(limit: Int = 50); var canUndo: Bool; var canRedo: Bool; mutating func commit(_ state: [Annotation]); mutating func undo(current: [Annotation]) -> [Annotation]?; mutating func redo(current: [Annotation]) -> [Annotation]? }`. `commit` captures the state *before* a mutation and clears the redo stack; `undo`/`redo` swap through `current`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SXAnnotateTests/AnnotationHistoryTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import SXAnnotate

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
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `AnnotationHistory` not defined.

- [ ] **Step 3: Implement the history**

Create `Sources/SXAnnotate/History/AnnotationHistory.swift`:

```swift
/// Value-snapshot undo/redo. Because `[Annotation]` is a value type, a copy is a
/// deep copy — no cloning machinery needed. Call `commit(current)` immediately
/// *before* mutating; `undo`/`redo` swap the caller's `current` through the stacks.
public struct AnnotationHistory: Sendable {
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private let limit: Int

    public init(limit: Int = 50) {
        self.limit = Swift.max(1, limit)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Snapshots the pre-mutation state and invalidates the redo history.
    public mutating func commit(_ state: [Annotation]) {
        undoStack.append(state)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    public mutating func undo(current: [Annotation]) -> [Annotation]? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    public mutating func redo(current: [Annotation]) -> [Annotation]? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS (all `AnnotationHistoryTests`).

- [ ] **Step 5: Commit**

```bash
git add Sources/SXAnnotate/History Tests/SXAnnotateTests/AnnotationHistoryTests.swift
git commit -m "Add value-snapshot undo/redo history"
```

---

### Task 5: Renderer

**Files:**
- Create: `Sources/SXAnnotate/Rendering/AnnotationRenderer.swift`
- Test: `Tests/SXAnnotateTests/AnnotationRendererTests.swift`

**Interfaces:**
- Consumes: `Annotation`, `AnnotationShape`, `AnnotationStyle`, `RGBAColor` (Tasks 1–3).
- Produces: `enum AnnotationRenderer { static func drawAnnotations(_ annotations: [Annotation], in ctx: CGContext); static func flatten(base: CGImage, annotations: [Annotation]) -> CGImage? }`. `drawAnnotations` draws in image-pixel coordinates under the context's current CTM (the caller sets up scale/flip). `flatten` composites base + annotations at native image resolution.

Design note: `drawAnnotations` is coordinate-space-agnostic — it strokes/fills using raw annotation coordinates and lets the caller's CTM place them. `flatten` draws the base right-side up in a native bottom-left context, then flips the CTM (top-left, y-down) before calling `drawAnnotations`, so both the exported image and the on-screen view (Task 7/9) share one drawing routine.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SXAnnotateTests/AnnotationRendererTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import SXAnnotate

@Suite struct AnnotationRendererTests {
    /// A solid white base image of the given size.
    private func whiteBase(_ w: Int, _ h: Int) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// Reads back pixels using top-left (image) coordinates.
    private struct Sampler {
        let w: Int, h: Int
        var buf: [UInt8]
        init(_ image: CGImage) {
            w = image.width; h = image.height
            buf = [UInt8](repeating: 0, count: w * h * 4)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        /// (r,g,b,a) at top-left pixel (x,y). The backing buffer is bottom-left, so flip the row.
        func rgba(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let row = h - 1 - y
            let i = (row * w + x) * 4
            return (buf[i], buf[i + 1], buf[i + 2], buf[i + 3])
        }
    }

    @Test func flattenPreservesBaseWhereUnannotated() {
        let out = AnnotationRenderer.flatten(base: whiteBase(60, 60), annotations: [])
        let s = Sampler(#require(out))
        let (r, g, b, _) = s.rgba(30, 30)
        #expect(r > 240 && g > 240 && b > 240)
    }

    @Test func filledRectanglePaintsItsInterior() throws {
        let fill = RGBAColor(r: 0, g: 0, b: 1, a: 1)  // blue
        let a = Annotation(id: .init(),
                           shape: .rectangle(rect: CGRect(x: 10, y: 10, width: 40, height: 40)),
                           style: AnnotationStyle(strokeColor: .clear, strokeWidth: 0, fillColor: fill))
        let out = try #require(AnnotationRenderer.flatten(base: whiteBase(60, 60), annotations: [a]))
        let s = Sampler(out)
        let (r, g, b, _) = s.rgba(30, 30)     // center of the rect
        #expect(b > 200 && r < 60 && g < 60)  // blue interior
        let (r2, _, _, _) = s.rgba(2, 2)      // outside the rect, still white base
        #expect(r2 > 240)
    }

    @Test func strokedLinePaintsAlongItsPath() throws {
        let stroke = RGBAColor(r: 1, g: 0, b: 0, a: 1)  // red
        let a = Annotation(id: .init(),
                           shape: .line(start: CGPoint(x: 5, y: 30), end: CGPoint(x: 55, y: 30)),
                           style: AnnotationStyle(strokeColor: stroke, strokeWidth: 6, fillColor: .clear))
        let out = try #require(AnnotationRenderer.flatten(base: whiteBase(60, 60), annotations: [a]))
        let s = Sampler(out)
        let (r, g, b, _) = s.rgba(30, 30)   // on the line
        #expect(r > 200 && g < 60 && b < 60)
        let (_, g2, _, _) = s.rgba(30, 5)   // well above the line, still white
        #expect(g2 > 240)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `AnnotationRenderer` not defined.

- [ ] **Step 3: Implement the renderer**

Create `Sources/SXAnnotate/Rendering/AnnotationRenderer.swift`:

```swift
import CoreGraphics

public enum AnnotationRenderer {
    /// Draws every annotation in image-pixel coordinates using the context's
    /// current CTM. The caller establishes the coordinate mapping (identity+flip
    /// for export, aspect-fit for the on-screen view).
    public static func drawAnnotations(_ annotations: [Annotation], in ctx: CGContext) {
        for annotation in annotations {
            draw(annotation, in: ctx)
        }
    }

    /// Composites `base` + `annotations` at native resolution. Returns nil only if
    /// a bitmap context cannot be created.
    public static func flatten(base: CGImage, annotations: [Annotation]) -> CGImage? {
        let w = base.width, h = base.height
        guard w > 0, h > 0,
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Base drawn right-side up in the native bottom-left context.
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Flip to top-left, y-down so annotation coordinates land correctly.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        drawAnnotations(annotations, in: ctx)
        return ctx.makeImage()
    }

    private static func draw(_ annotation: Annotation, in ctx: CGContext) {
        let style = annotation.style
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(CGFloat(style.strokeWidth))

        switch annotation.shape {
        case .rectangle(let rect):
            fillThenStroke(rect: rect.standardized, isEllipse: false, style: style, ctx: ctx)
        case .ellipse(let rect):
            fillThenStroke(rect: rect.standardized, isEllipse: true, style: style, ctx: ctx)
        case .line(let start, let end):
            strokePath(style: style, ctx: ctx) { $0.move(to: start); $0.addLine(to: end) }
        case .arrow(let start, let end):
            drawArrow(from: start, to: end, style: style, ctx: ctx)
        case .freehand(let points):
            guard points.count > 1 else { break }
            strokePath(style: style, ctx: ctx) {
                $0.move(to: points[0])
                for p in points.dropFirst() { $0.addLine(to: p) }
            }
        }
        ctx.restoreGState()
    }

    private static func fillThenStroke(rect: CGRect, isEllipse: Bool,
                                       style: AnnotationStyle, ctx: CGContext) {
        let path = CGMutablePath()
        if isEllipse { path.addEllipse(in: rect) } else { path.addRect(rect) }
        if !style.fillColor.isClear {
            ctx.addPath(path)
            ctx.setFillColor(style.fillColor.cgColor)
            ctx.fillPath()
        }
        if !style.strokeColor.isClear && style.strokeWidth > 0 {
            ctx.addPath(path)
            ctx.setStrokeColor(style.strokeColor.cgColor)
            ctx.strokePath()
        }
    }

    private static func strokePath(style: AnnotationStyle, ctx: CGContext,
                                   build: (CGMutablePath) -> Void) {
        guard !style.strokeColor.isClear, style.strokeWidth > 0 else { return }
        let path = CGMutablePath()
        build(path)
        ctx.addPath(path)
        ctx.setStrokeColor(style.strokeColor.cgColor)
        ctx.strokePath()
    }

    /// A straight shaft plus a filled classic arrowhead sized from the stroke width.
    private static func drawArrow(from start: CGPoint, to end: CGPoint,
                                  style: AnnotationStyle, ctx: CGContext) {
        guard !style.strokeColor.isClear, style.strokeWidth > 0 else { return }
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        ctx.setStrokeColor(style.strokeColor.cgColor)
        ctx.setFillColor(style.strokeColor.cgColor)
        guard length > 0.5 else { return }
        let ux = dx / length, uy = dy / length                 // unit direction
        let headLength = Swift.max(12, CGFloat(style.strokeWidth) * 3)
        let headHalfWidth = Swift.max(7, CGFloat(style.strokeWidth) * 1.8)
        // Shaft stops at the base of the head so it doesn't poke through the tip.
        let baseX = end.x - ux * headLength, baseY = end.y - uy * headLength
        let shaft = CGMutablePath()
        shaft.move(to: start)
        shaft.addLine(to: CGPoint(x: baseX, y: baseY))
        ctx.addPath(shaft)
        ctx.strokePath()
        // Filled triangle: tip at end, two wings perpendicular to the direction.
        let px = -uy, py = ux                                   // perpendicular unit
        let head = CGMutablePath()
        head.move(to: end)
        head.addLine(to: CGPoint(x: baseX + px * headHalfWidth, y: baseY + py * headHalfWidth))
        head.addLine(to: CGPoint(x: baseX - px * headHalfWidth, y: baseY - py * headHalfWidth))
        head.closeSubpath()
        ctx.addPath(head)
        ctx.fillPath()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS (all `AnnotationRendererTests`).

- [ ] **Step 5: Commit**

```bash
git add Sources/SXAnnotate/Rendering/AnnotationRenderer.swift Tests/SXAnnotateTests/AnnotationRendererTests.swift
git commit -m "Add CoreGraphics annotation renderer and flatten"
```

---

### Task 6: Snapshot golden regression test

**Files:**
- Create: `Tests/SXAnnotateTests/SnapshotTests.swift`
- Create: `Tests/SXAnnotateTests/Fixtures/composite.png` (generated on the Mac in Step 3)
- Test: same file

**Interfaces:**
- Consumes: `AnnotationRenderer.flatten` (Task 5).
- Produces: a tolerance-based image comparison that guards the renderer against regressions (spec §6 "Snapshot (CI-run): render annotation documents → PNG, pixel-diff against goldens"). Tolerance is generous to absorb cross-OS-version anti-aliasing differences (dev Mac SDK ≠ CI SDK).

Note on approach: point-sampling (Task 5) already asserts exact colors; this task adds one composite golden as a whole-image regression guard. The comparison uses mean per-channel difference, not exact equality, so sub-pixel AA differences between the dev SDK and the `macos-15` CI SDK do not cause false failures.

- [ ] **Step 1: Write the snapshot test (it will fail until the golden exists)**

Create `Tests/SXAnnotateTests/SnapshotTests.swift`:

```swift
import Testing
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import SXAnnotate

@Suite struct SnapshotTests {
    /// A representative document exercising every vector shape.
    static func compositeImage() -> CGImage {
        let w = 200, h = 150
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let base = ctx.makeImage()!
        let red = RGBAColor.red
        let blueFill = RGBAColor(r: 0.2, g: 0.4, b: 0.9, a: 0.5)
        let annotations: [Annotation] = [
            Annotation(id: .init(), shape: .rectangle(rect: CGRect(x: 10, y: 10, width: 60, height: 40)),
                       style: AnnotationStyle(strokeColor: red, strokeWidth: 4, fillColor: blueFill)),
            Annotation(id: .init(), shape: .ellipse(rect: CGRect(x: 90, y: 15, width: 50, height: 30)),
                       style: AnnotationStyle(strokeColor: red, strokeWidth: 4)),
            Annotation(id: .init(), shape: .line(start: CGPoint(x: 10, y: 90), end: CGPoint(x: 90, y: 120)),
                       style: AnnotationStyle(strokeColor: red, strokeWidth: 5)),
            Annotation(id: .init(), shape: .arrow(start: CGPoint(x: 110, y: 120), end: CGPoint(x: 180, y: 80)),
                       style: AnnotationStyle(strokeColor: red, strokeWidth: 5)),
            Annotation(id: .init(), shape: .freehand(points: [
                CGPoint(x: 150, y: 20), CGPoint(x: 165, y: 40), CGPoint(x: 150, y: 55), CGPoint(x: 175, y: 60)]),
                       style: AnnotationStyle(strokeColor: red, strokeWidth: 3)),
        ]
        return AnnotationRenderer.flatten(base: base, annotations: annotations)!
    }

    private func pngData(_ image: CGImage) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func load(_ data: Data) -> CGImage {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCreateImageAtIndex(src, 0, nil)!
    }

    /// Mean absolute per-channel difference (0…255) between two same-size images.
    private func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
        precondition(a.width == b.width && a.height == b.height)
        let w = a.width, h = a.height
        func bytes(_ img: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buf
        }
        let ba = bytes(a), bb = bytes(b)
        var total = 0.0
        for i in 0..<ba.count { total += Double(abs(Int(ba[i]) - Int(bb[i]))) }
        return total / Double(ba.count)
    }

    @Test func compositeMatchesGolden() throws {
        let rendered = Self.compositeImage()
        let goldenURL = Bundle.module.url(forResource: "composite", withExtension: "png", subdirectory: "Fixtures")
        let golden = try load(#require(Data(contentsOf: #require(goldenURL))))
        // Generous tolerance: absorbs cross-SDK anti-aliasing, catches real regressions.
        #expect(meanDifference(rendered, golden) < 4.0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/remote.sh test`
Expected: FAIL — the golden fixture does not exist yet (`goldenURL` is nil → `#require` throws).

- [ ] **Step 3: Generate and commit the golden**

The golden must be produced by the same renderer on the Mac. Add a temporary generator test, run it once, copy the output into `Fixtures/`, then delete the generator.

Temporarily append this to `SnapshotTests.swift`:

```swift
    @Test func generateGolden() throws {
        let data = pngData(Self.compositeImage())
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("composite.png")
        try data.write(to: url)
        print("GOLDEN_WRITTEN \(url.path)")
    }
```

Run it and copy the result into the fixtures directory over SSH:

```bash
scripts/remote.sh test 2>&1 | grep GOLDEN_WRITTEN
# On the Mac, the file is at $TMPDIR/composite.png. Pull it into the repo:
scripts/remote.sh ssh "cat \$TMPDIR/composite.png" > Tests/SXAnnotateTests/Fixtures/composite.png
```

Verify the file is a non-empty PNG (`file Tests/SXAnnotateTests/Fixtures/composite.png` → "PNG image data"). Then remove the temporary `generateGolden` test from `SnapshotTests.swift`.

- [ ] **Step 4: Run the snapshot test to verify it passes**

Run: `scripts/remote.sh test`
Expected: PASS — `compositeMatchesGolden` (mean difference well under 4.0, typically ~0).

- [ ] **Step 5: Commit**

```bash
git add Tests/SXAnnotateTests/SnapshotTests.swift Tests/SXAnnotateTests/Fixtures/composite.png
git commit -m "Add composite snapshot golden regression test"
```

---

### Task 7: Canvas geometry (aspect-fit transform)

**Files:**
- Create: `Sources/SXAnnotate/Rendering/CanvasGeometry.swift`
- Test: `Tests/SXAnnotateTests/CanvasGeometryTests.swift`

**Interfaces:**
- Consumes: nothing beyond CoreGraphics.
- Produces: `struct CanvasGeometry: Sendable { init(imageSize: CGSize, viewSize: CGSize); var imageRectInView: CGRect; var scale: CGFloat; var imageToViewTransform: CGAffineTransform; func viewToImage(_ p: CGPoint) -> CGPoint; func imageToView(_ p: CGPoint) -> CGPoint }`. Maps between image space (top-left, y-down) and an aspect-fit, centered rect in a **non-flipped** AppKit view (bottom-left, y-up).

- [ ] **Step 1: Write the failing tests**

Create `Tests/SXAnnotateTests/CanvasGeometryTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import SXAnnotate

@Suite struct CanvasGeometryTests {
    @Test func fitsWideImageWithVerticalLetterbox() {
        // 100x50 image in a 200x200 view → scale 2, displayed 200x100, centered vertically.
        let g = CanvasGeometry(imageSize: CGSize(width: 100, height: 50),
                               viewSize: CGSize(width: 200, height: 200))
        #expect(g.scale == 2)
        #expect(g.imageRectInView == CGRect(x: 0, y: 50, width: 200, height: 100))
    }

    @Test func imageTopLeftMapsToDisplayedTopLeftInView() {
        let g = CanvasGeometry(imageSize: CGSize(width: 100, height: 50),
                               viewSize: CGSize(width: 200, height: 200))
        // Image (0,0) top-left → top of the displayed rect (view y is up, so the top is y = 150).
        let v = g.imageToView(CGPoint(x: 0, y: 0))
        #expect(v.x == 0)
        #expect(v.y == 150)
        // Image bottom-right (100,50) → bottom-right of the displayed rect (view y = 50).
        let v2 = g.imageToView(CGPoint(x: 100, y: 50))
        #expect(v2.x == 200)
        #expect(v2.y == 50)
    }

    @Test func viewToImageInvertsImageToView() {
        let g = CanvasGeometry(imageSize: CGSize(width: 120, height: 80),
                               viewSize: CGSize(width: 300, height: 300))
        for p in [CGPoint(x: 10, y: 10), CGPoint(x: 119, y: 1), CGPoint(x: 60, y: 79)] {
            let back = g.viewToImage(g.imageToView(p))
            #expect(abs(back.x - p.x) < 0.001)
            #expect(abs(back.y - p.y) < 0.001)
        }
    }

    @Test func transformMatchesImageToView() {
        let g = CanvasGeometry(imageSize: CGSize(width: 100, height: 50),
                               viewSize: CGSize(width: 200, height: 200))
        let p = CGPoint(x: 40, y: 25)
        let viaTransform = p.applying(g.imageToViewTransform)
        let viaFunc = g.imageToView(p)
        #expect(abs(viaTransform.x - viaFunc.x) < 0.001)
        #expect(abs(viaTransform.y - viaFunc.y) < 0.001)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `CanvasGeometry` not defined.

- [ ] **Step 3: Implement CanvasGeometry**

Create `Sources/SXAnnotate/Rendering/CanvasGeometry.swift`:

```swift
import CoreGraphics

/// Maps between image-pixel space (top-left origin, y-down) and a centered,
/// aspect-fit rectangle inside a non-flipped AppKit view (bottom-left, y-up).
public struct CanvasGeometry: Sendable {
    public let imageSize: CGSize
    public let viewSize: CGSize
    public let scale: CGFloat
    public let imageRectInView: CGRect

    public init(imageSize: CGSize, viewSize: CGSize) {
        self.imageSize = imageSize
        self.viewSize = viewSize
        let s: CGFloat
        if imageSize.width > 0 && imageSize.height > 0 {
            s = Swift.min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        } else {
            s = 1
        }
        self.scale = s
        let dispW = imageSize.width * s, dispH = imageSize.height * s
        self.imageRectInView = CGRect(x: (viewSize.width - dispW) / 2,
                                      y: (viewSize.height - dispH) / 2,
                                      width: dispW, height: dispH)
    }

    /// image(top-left, y-down) → view(bottom-left, y-up).
    public var imageToViewTransform: CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                          tx: imageRectInView.minX,
                          ty: imageRectInView.minY + imageRectInView.height)
    }

    public func imageToView(_ p: CGPoint) -> CGPoint {
        p.applying(imageToViewTransform)
    }

    public func viewToImage(_ p: CGPoint) -> CGPoint {
        guard scale != 0 else { return .zero }
        return CGPoint(x: (p.x - imageRectInView.minX) / scale,
                       y: (imageRectInView.minY + imageRectInView.height - p.y) / scale)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS (all `CanvasGeometryTests`).

- [ ] **Step 5: Commit**

```bash
git add Sources/SXAnnotate/Rendering/CanvasGeometry.swift Tests/SXAnnotateTests/CanvasGeometryTests.swift
git commit -m "Add aspect-fit canvas geometry transform"
```

---

### Task 8: EditorModel interaction state machine

**Files:**
- Create: `Sources/SXAnnotate/Editor/EditorModel.swift`
- Test: `Tests/SXAnnotateTests/EditorModelTests.swift`

**Interfaces:**
- Consumes: `Annotation`, `AnnotationShape`, `AnnotationStyle`, `RGBAColor`, `EditorTool`, `HandleKind`, `AnnotationHistory`, `AnnotationRenderer` (Tasks 1–5), `CGRect(spanning:_:)` (Task 2).
- Produces: `@MainActor final class EditorModel: ObservableObject` with published `annotations`, `activeTool`, `strokeColor`, `strokeWidth`, `selectedID`, `canUndo`, `canRedo`; `init(baseImage: CGImage)`; `let baseImage: CGImage`; `var selectedAnnotation: Annotation?`; `var displayAnnotations: [Annotation]`; `func pointerDown(at:)`, `func pointerDragged(to:)`, `func pointerUp(at:)` (all in image coordinates); `func deleteSelected()`, `func undo()`, `func redo()`, `func setTool(_:)`, `func flatten() -> CGImage?`. Constant `handleTolerance: CGFloat` and `hitTolerance: CGFloat`.

Interaction contract (image coordinates):
- **Select tool:** pointerDown checks the selected annotation's handles first (begin resize), else the topmost annotation under the point (select + begin move), else deselects. Drag moves/resizes live; up finalizes.
- **Drawing tool:** pointerDown starts a draft anchored at the point; drag grows it; up appends it if non-degenerate (box > 3×3, line/arrow endpoint distance > 3, freehand > 1 point) and selects it, else discards.
- **History:** exactly one undo entry per gesture, recorded only if the document actually changed.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SXAnnotateTests/EditorModelTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import SXAnnotate

@MainActor @Suite struct EditorModelTests {
    private func base(_ w: Int = 100, _ h: Int = 100) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    @Test func drawingARectangleAppendsOneAnnotation() {
        let m = EditorModel(baseImage: base())
        m.setTool(.rectangle)
        m.pointerDown(at: CGPoint(x: 10, y: 10))
        m.pointerDragged(to: CGPoint(x: 60, y: 40))
        m.pointerUp(at: CGPoint(x: 60, y: 40))
        #expect(m.annotations.count == 1)
        #expect(m.annotations[0].bounds == CGRect(x: 10, y: 10, width: 50, height: 30))
        #expect(m.selectedID == m.annotations[0].id)
        #expect(m.canUndo)
    }

    @Test func degenerateDraftIsDiscarded() {
        let m = EditorModel(baseImage: base())
        m.setTool(.rectangle)
        m.pointerDown(at: CGPoint(x: 10, y: 10))
        m.pointerDragged(to: CGPoint(x: 11, y: 11))   // below the 3x3 threshold
        m.pointerUp(at: CGPoint(x: 11, y: 11))
        #expect(m.annotations.isEmpty)
        #expect(!m.canUndo)
    }

    @Test func drawingUsesTheCurrentStyle() {
        let m = EditorModel(baseImage: base())
        m.strokeWidth = 9
        m.strokeColor = RGBAColor(r: 0, g: 1, b: 0, a: 1)
        m.setTool(.line)
        m.pointerDown(at: CGPoint(x: 0, y: 0))
        m.pointerDragged(to: CGPoint(x: 40, y: 0))
        m.pointerUp(at: CGPoint(x: 40, y: 0))
        #expect(m.annotations[0].style.strokeWidth == 9)
        #expect(m.annotations[0].style.strokeColor == RGBAColor(r: 0, g: 1, b: 0, a: 1))
    }

    @Test func selectToolMovesAnExistingAnnotation() {
        let m = EditorModel(baseImage: base())
        m.setTool(.rectangle)
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 60, y: 60)); m.pointerUp(at: CGPoint(x: 60, y: 60))
        m.setTool(.select)
        m.pointerDown(at: CGPoint(x: 35, y: 35))   // inside the rect
        m.pointerDragged(to: CGPoint(x: 45, y: 45)) // move by (10,10)
        m.pointerUp(at: CGPoint(x: 45, y: 45))
        #expect(m.annotations[0].bounds == CGRect(x: 20, y: 20, width: 50, height: 50))
    }

    @Test func selectToolResizesViaHandle() {
        let m = EditorModel(baseImage: base())
        m.setTool(.rectangle)
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 60, y: 60)); m.pointerUp(at: CGPoint(x: 60, y: 60))
        m.setTool(.select)
        m.pointerDown(at: CGPoint(x: 10, y: 10))    // grab the top-left handle
        m.pointerDragged(to: CGPoint(x: 0, y: 0))
        m.pointerUp(at: CGPoint(x: 0, y: 0))
        #expect(m.annotations[0].bounds == CGRect(x: 0, y: 0, width: 60, height: 60))
    }

    @Test func clickingEmptySpaceDeselects() {
        let m = EditorModel(baseImage: base())
        m.setTool(.rectangle)
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 40, y: 40)); m.pointerUp(at: CGPoint(x: 40, y: 40))
        m.setTool(.select)
        m.pointerDown(at: CGPoint(x: 90, y: 90)); m.pointerUp(at: CGPoint(x: 90, y: 90))
        #expect(m.selectedID == nil)
    }

    @Test func deleteRemovesTheSelection() {
        let m = EditorModel(baseImage: base())
        m.setTool(.rectangle)
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 40, y: 40)); m.pointerUp(at: CGPoint(x: 40, y: 40))
        m.deleteSelected()
        #expect(m.annotations.isEmpty)
        #expect(m.selectedID == nil)
        #expect(m.canUndo)
    }

    @Test func undoRedoRoundTripsADrawnShape() {
        let m = EditorModel(baseImage: base())
        m.setTool(.ellipse)
        m.pointerDown(at: CGPoint(x: 10, y: 10)); m.pointerDragged(to: CGPoint(x: 50, y: 50)); m.pointerUp(at: CGPoint(x: 50, y: 50))
        #expect(m.annotations.count == 1)
        m.undo()
        #expect(m.annotations.isEmpty)
        #expect(m.canRedo)
        m.redo()
        #expect(m.annotations.count == 1)
    }

    @Test func flattenProducesAnImageOfBaseSize() {
        let m = EditorModel(baseImage: base(80, 60))
        m.setTool(.rectangle)
        m.pointerDown(at: CGPoint(x: 5, y: 5)); m.pointerDragged(to: CGPoint(x: 30, y: 30)); m.pointerUp(at: CGPoint(x: 30, y: 30))
        let out = m.flatten()
        #expect(out?.width == 80)
        #expect(out?.height == 60)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `EditorModel` not defined.

- [ ] **Step 3: Implement EditorModel**

Create `Sources/SXAnnotate/Editor/EditorModel.swift`:

```swift
import CoreGraphics
import Combine

/// The interaction state machine and document owner for one editing session.
/// UI-agnostic: the AppKit canvas forwards pointer events (in image coordinates)
/// and observes the published state. All mutation flows through here so undo
/// history and selection stay consistent.
@MainActor
public final class EditorModel: ObservableObject {
    public let baseImage: CGImage

    @Published public private(set) var annotations: [Annotation] = []
    @Published public var activeTool: EditorTool = .select
    @Published public var strokeColor: RGBAColor = .red
    @Published public var strokeWidth: Double = 4
    @Published public private(set) var selectedID: Annotation.ID?
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false

    public let hitTolerance: CGFloat = 8
    public let handleTolerance: CGFloat = 9

    private var history = AnnotationHistory()

    // Per-gesture transient state.
    private var draft: Annotation?           // shape being drawn
    private var drawAnchor: CGPoint?         // draw start point
    private var activeHandle: HandleKind?    // resize in progress
    private var lastDragPoint: CGPoint?      // move in progress
    private var gestureStartState: [Annotation]?  // document before the gesture

    public init(baseImage: CGImage) {
        self.baseImage = baseImage
    }

    public var selectedAnnotation: Annotation? {
        guard let id = selectedID else { return nil }
        return annotations.first { $0.id == id }
    }

    /// The document plus any in-progress draft, for live rendering.
    public var displayAnnotations: [Annotation] {
        if let draft { return annotations + [draft] }
        return annotations
    }

    public func setTool(_ tool: EditorTool) {
        activeTool = tool
        if tool != .select { selectedID = nil }
    }

    private var currentStyle: AnnotationStyle {
        AnnotationStyle(strokeColor: strokeColor, strokeWidth: strokeWidth, fillColor: .clear)
    }

    // MARK: Pointer handling

    public func pointerDown(at point: CGPoint) {
        gestureStartState = annotations
        if activeTool == .select {
            beginSelectGesture(at: point)
        } else {
            beginDraw(at: point)
        }
    }

    public func pointerDragged(to point: CGPoint) {
        if draft != nil, let anchor = drawAnchor {
            draft = updatedDraft(anchor: anchor, to: point)
        } else if let handle = activeHandle, let id = selectedID,
                  let index = annotations.firstIndex(where: { $0.id == id }) {
            annotations[index] = annotations[index].resized(handle: handle, to: point)
        } else if let last = lastDragPoint, let id = selectedID,
                  let index = annotations.firstIndex(where: { $0.id == id }) {
            let delta = CGVector(dx: point.x - last.x, dy: point.y - last.y)
            annotations[index] = annotations[index].moved(by: delta)
            lastDragPoint = point
        }
    }

    public func pointerUp(at point: CGPoint) {
        if let draft, let anchor = drawAnchor {
            let finished = updatedDraft(anchor: anchor, to: point)
            if isNonDegenerate(finished) {
                annotations.append(finished)
                selectedID = finished.id
            }
        }
        commitGestureIfChanged()
        draft = nil
        drawAnchor = nil
        activeHandle = nil
        lastDragPoint = nil
    }

    // MARK: Commands

    public func deleteSelected() {
        guard let id = selectedID, annotations.contains(where: { $0.id == id }) else { return }
        history.commit(annotations)
        annotations.removeAll { $0.id == id }
        selectedID = nil
        refreshHistoryFlags()
    }

    public func undo() {
        guard let previous = history.undo(current: annotations) else { return }
        annotations = previous
        clampSelection()
        refreshHistoryFlags()
    }

    public func redo() {
        guard let next = history.redo(current: annotations) else { return }
        annotations = next
        clampSelection()
        refreshHistoryFlags()
    }

    public func flatten() -> CGImage? {
        AnnotationRenderer.flatten(base: baseImage, annotations: annotations)
    }

    // MARK: Gesture internals

    private func beginSelectGesture(at point: CGPoint) {
        // Resize takes priority when a selected shape's handle is under the cursor.
        if let selected = selectedAnnotation,
           let handle = selected.handle(at: point, tolerance: handleTolerance) {
            activeHandle = handle
            return
        }
        // Otherwise pick the topmost annotation under the point.
        if let hit = annotations.last(where: { $0.hitTest(point, tolerance: hitTolerance) }) {
            selectedID = hit.id
            lastDragPoint = point
        } else {
            selectedID = nil
        }
    }

    private func beginDraw(at point: CGPoint) {
        drawAnchor = point
        draft = Annotation(shape: shape(for: activeTool, anchor: point, to: point),
                           style: currentStyle)
    }

    private func shape(for tool: EditorTool, anchor: CGPoint, to point: CGPoint) -> AnnotationShape {
        switch tool {
        case .rectangle: return .rectangle(rect: CGRect(spanning: anchor, point))
        case .ellipse:   return .ellipse(rect: CGRect(spanning: anchor, point))
        case .line:      return .line(start: anchor, end: point)
        case .arrow:     return .arrow(start: anchor, end: point)
        case .freehand:  return .freehand(points: [anchor])
        case .select:    return .rectangle(rect: CGRect(spanning: anchor, point))  // unreachable
        }
    }

    private func updatedDraft(anchor: CGPoint, to point: CGPoint) -> Annotation {
        guard var current = draft else {
            return Annotation(shape: shape(for: activeTool, anchor: anchor, to: point), style: currentStyle)
        }
        switch activeTool {
        case .rectangle: current.shape = .rectangle(rect: CGRect(spanning: anchor, point))
        case .ellipse:   current.shape = .ellipse(rect: CGRect(spanning: anchor, point))
        case .line:      current.shape = .line(start: anchor, end: point)
        case .arrow:     current.shape = .arrow(start: anchor, end: point)
        case .freehand:
            if case .freehand(var points) = current.shape {
                points.append(point)
                current.shape = .freehand(points: points)
            }
        case .select:
            break
        }
        return current
    }

    private func isNonDegenerate(_ annotation: Annotation) -> Bool {
        switch annotation.shape {
        case .rectangle(let rect), .ellipse(let rect):
            return rect.width > 3 && rect.height > 3
        case .line(let s, let e), .arrow(let s, let e):
            return hypot(e.x - s.x, e.y - s.y) > 3
        case .freehand(let points):
            return points.count > 1
        }
    }

    private func commitGestureIfChanged() {
        guard let before = gestureStartState else { return }
        gestureStartState = nil
        if before != annotations {
            history.commit(before)
            refreshHistoryFlags()
        }
    }

    private func clampSelection() {
        if let id = selectedID, !annotations.contains(where: { $0.id == id }) {
            selectedID = nil
        }
    }

    private func refreshHistoryFlags() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: PASS (all `EditorModelTests`).

- [ ] **Step 5: Commit**

```bash
git add Sources/SXAnnotate/Editor/EditorModel.swift Tests/SXAnnotateTests/EditorModelTests.swift
git commit -m "Add EditorModel interaction state machine"
```

---

### Task 9: AppKit canvas view + representable

**Files:**
- Create: `Sources/SXApp/EditorCanvasView.swift`
- Test: build only (executable-target UI; covered by the Mac smoke checklist, matching the project's existing convention that `SXApp` glue is smoke-tested).

**Interfaces:**
- Consumes: `EditorModel`, `AnnotationRenderer`, `CanvasGeometry`, `Annotation.handles()` (SXAnnotate).
- Produces: `final class EditorCanvasNSView: NSView` (draws base + annotations + selection chrome; forwards mouse events to the model in image coordinates); `struct EditorCanvasView: NSViewRepresentable` (SwiftUI wrapper binding an `EditorModel`).

Design note: the `NSView` stays **non-flipped**; all coordinate inversion is `CanvasGeometry`'s. It draws the base image into `imageRectInView`, concatenates `imageToViewTransform` and calls `AnnotationRenderer.drawAnnotations(model.displayAnnotations,…)`, then draws selection handles for `model.selectedAnnotation` in view space (so they never appear in exports). The representable's `updateNSView` triggers `needsDisplay` so published model changes repaint.

- [ ] **Step 1: Implement the canvas view**

Create `Sources/SXApp/EditorCanvasView.swift`:

```swift
import AppKit
import SwiftUI
import SXAnnotate

/// Custom AppKit canvas: renders the document with `AnnotationRenderer` and
/// forwards pointer events (converted to image coordinates) to `EditorModel`.
final class EditorCanvasNSView: NSView {
    let model: EditorModel

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }

    private var geometry: CanvasGeometry {
        CanvasGeometry(imageSize: CGSize(width: model.baseImage.width, height: model.baseImage.height),
                       viewSize: bounds.size)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let geo = geometry

        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(model.baseImage, in: geo.imageRectInView)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.concatenate(geo.imageToViewTransform)
        AnnotationRenderer.drawAnnotations(model.displayAnnotations, in: ctx)
        ctx.restoreGState()

        if let selected = model.selectedAnnotation {
            drawSelection(selected, geo: geo, in: ctx)
        }
    }

    private func drawSelection(_ annotation: Annotation, geo: CanvasGeometry, in ctx: CGContext) {
        // Dashed bounding outline.
        let b = annotation.bounds
        let corners = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                       CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
            .map { geo.imageToView($0) }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.addLines(between: corners + [corners[0]])
        ctx.strokePath()
        ctx.restoreGState()

        // Solid grips.
        ctx.saveGState()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        for handle in annotation.handles() {
            let c = geo.imageToView(handle.point)
            let r = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
            ctx.fillEllipse(in: r)
            ctx.strokeEllipse(in: r)
        }
        ctx.restoreGState()
    }

    // MARK: Mouse

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        geometry.viewToImage(convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        model.pointerDown(at: imagePoint(event)); needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        model.pointerDragged(to: imagePoint(event)); needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        model.pointerUp(at: imagePoint(event)); needsDisplay = true
    }
}

/// SwiftUI bridge for the AppKit canvas.
struct EditorCanvasView: NSViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeNSView(context: Context) -> EditorCanvasNSView {
        EditorCanvasNSView(model: model)
    }

    func updateNSView(_ nsView: EditorCanvasNSView, context: Context) {
        nsView.needsDisplay = true
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `scripts/remote.sh build`
Expected: build succeeds with no errors or new warnings.

- [ ] **Step 3: Commit**

```bash
git add Sources/SXApp/EditorCanvasView.swift
git commit -m "Add AppKit editor canvas view and SwiftUI representable"
```

---

### Task 10: SwiftUI editor view (toolbar + inspector)

**Files:**
- Create: `Sources/SXApp/EditorView.swift`
- Test: build only (Mac smoke checklist).

**Interfaces:**
- Consumes: `EditorModel`, `EditorTool`, `RGBAColor`, `EditorCanvasView` (Task 9).
- Produces: `struct EditorView: View` — a toolbar (tool picker + stroke color/width + undo/redo/delete), the canvas, and Done/Cancel actions wired to closures `onDone: (CGImage) -> Void` and `onCancel: () -> Void`.

Design note: `RGBAColor` ↔ SwiftUI `Color` conversion lives here (a small `Color(rgba:)` init and an `RGBAColor(color:)` reader via `NSColor`), so SXAnnotate stays SwiftUI-free.

- [ ] **Step 1: Implement the editor view**

Create `Sources/SXApp/EditorView.swift`:

```swift
import SwiftUI
import AppKit
import SXAnnotate

private extension Color {
    init(rgba: RGBAColor) {
        self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}

private extension RGBAColor {
    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .red
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent),
                  b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }
}

struct EditorView: View {
    @ObservedObject var model: EditorModel
    let onDone: (CGImage) -> Void
    let onCancel: () -> Void

    private let tools: [(EditorTool, String, String)] = [
        (.select, "Select", "cursorarrow"),
        (.rectangle, "Rectangle", "rectangle"),
        (.ellipse, "Ellipse", "circle"),
        (.line, "Line", "line.diagonal"),
        (.arrow, "Arrow", "arrow.up.right"),
        (.freehand, "Freehand", "scribble"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            EditorCanvasView(model: model)
                .frame(minWidth: 480, minHeight: 360)
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            ForEach(tools, id: \.0) { tool, label, symbol in
                Button {
                    model.setTool(tool)
                } label: {
                    Image(systemName: symbol)
                        .frame(width: 22, height: 22)
                }
                .help(label)
                .buttonStyle(.borderless)
                .background(model.activeTool == tool
                            ? Color.accentColor.opacity(0.25) : Color.clear)
                .cornerRadius(4)
            }

            Divider().frame(height: 20)

            ColorPicker("", selection: Binding(
                get: { Color(rgba: model.strokeColor) },
                set: { model.strokeColor = RGBAColor(color: $0) }))
                .labelsHidden()
                .help("Stroke color")

            Slider(value: $model.strokeWidth, in: 1...40)
                .frame(width: 90)
                .help("Stroke width")

            Divider().frame(height: 20)

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo).help("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo).help("Redo")
            Button { model.deleteSelected() } label: { Image(systemName: "trash") }
                .disabled(model.selectedAnnotation == nil).help("Delete selected")

            Spacer()

            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Done") {
                if let image = model.flatten() { onDone(image) } else { onCancel() }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(8)
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `scripts/remote.sh build`
Expected: build succeeds with no errors or new warnings.

- [ ] **Step 3: Commit**

```bash
git add Sources/SXApp/EditorView.swift
git commit -m "Add SwiftUI editor toolbar and view"
```

---

### Task 11: Editor window controller + EditorPresenting protocol

**Files:**
- Create: `Sources/SXApp/EditorWindowController.swift`
- Test: build only (Mac smoke checklist).

**Interfaces:**
- Consumes: `EditorModel`, `EditorView` (Tasks 8, 10).
- Produces: `@MainActor protocol EditorPresenting { func present(image: CGImage, completion: @escaping @MainActor (CGImage?) -> Void) }`; `@MainActor final class EditorWindowController: EditorPresenting` — hosts `EditorView` in an `NSWindow` (same pattern as `HistoryWindowController`), calls `completion` exactly once with the flattened image (Done) or `nil` (Cancel / window closed).

Design note: the completion is guarded by a `finished` flag so closing the window after Done doesn't fire it twice, and closing via the red button (without Done) fires `completion(nil)` — an intentional discard (Global Constraints: local-first). One editing session at a time.

- [ ] **Step 1: Implement the window controller**

Create `Sources/SXApp/EditorWindowController.swift`:

```swift
import AppKit
import SwiftUI
import SXAnnotate

@MainActor
protocol EditorPresenting {
    /// Presents the editor for `image`. Calls `completion` once: the flattened
    /// image on Done, or nil if the user cancelled/closed without finishing.
    func present(image: CGImage, completion: @escaping @MainActor (CGImage?) -> Void)
}

@MainActor
final class EditorWindowController: NSObject, EditorPresenting, NSWindowDelegate {
    private var window: NSWindow?
    private var completion: ((CGImage?) -> Void)?
    private var finished = false

    func present(image: CGImage, completion: @escaping @MainActor (CGImage?) -> Void) {
        // One session at a time; a new capture supersedes any stale window.
        if window != nil { finish(nil) }
        self.completion = completion
        self.finished = false

        let model = EditorModel(baseImage: image)
        let view = EditorView(
            model: model,
            onDone: { [weak self] edited in self?.finish(edited) },
            onCancel: { [weak self] in self?.finish(nil) })
        let hosting = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: hosting)
        w.title = "Edit Capture"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 900, height: 640))
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }

    private func finish(_ image: CGImage?) {
        guard !finished else { return }
        finished = true
        let callback = completion
        completion = nil
        window?.delegate = nil
        window?.close()
        window = nil
        callback?(image)
    }

    // Closing the window via the red button is a cancel (discard).
    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `scripts/remote.sh build`
Expected: build succeeds with no errors or new warnings.

- [ ] **Step 3: Commit**

```bash
git add Sources/SXApp/EditorWindowController.swift
git commit -m "Add editor window controller and EditorPresenting protocol"
```

---

### Task 12: Editor settings + pipeline gate + menu

**Files:**
- Modify: `Sources/SXCore/AppSettings.swift`
- Modify: `Sources/SXApp/CaptureCoordinator.swift`
- Modify: `Sources/SXApp/AppDelegate.swift`
- Test: `Tests/SXCoreTests/EditorSettingsTests.swift` (settings round-trip); the gate is covered by the Mac smoke checklist.

**Interfaces:**
- Consumes: `EditorPresenting`, `EditorWindowController` (Task 11); existing `AppSettings`, `CaptureCoordinator.deliver`, `AppDelegate.buildMenu` (current code).
- Produces: `struct EditorSettings: Codable, Equatable, Sendable { var annotateBeforeShare: Bool }` with `.default`; `AppSettings.editor: EditorSettings`; a gate in `CaptureCoordinator.deliver` that routes through an injected `EditorPresenting` when `settings.editor.annotateBeforeShare`; an "Annotate Before Sharing" menu toggle.

Design note: `editor` is an additive, tolerant field decoded with `decodeIfPresent(...) ?? .default`, exactly like `upload` — old v2 settings files load unchanged, no schema bump. `deliver` is split so the existing encode→pipeline path becomes `finish(image:appName:)`; the gate calls the presenter and runs `finish` on the edited image, or discards on cancel.

- [ ] **Step 1: Write the failing settings test**

Create `Tests/SXCoreTests/EditorSettingsTests.swift`:

```swift
import Testing
import Foundation
@testable import SXCore

@Suite struct EditorSettingsTests {
    @Test func defaultDisablesAnnotateBeforeShare() {
        #expect(AppSettings.default.editor.annotateBeforeShare == false)
    }

    @Test func settingsRoundTripPreservesEditor() throws {
        var s = AppSettings.default
        s.editor.annotateBeforeShare = true
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.editor.annotateBeforeShare == true)
    }

    @Test func legacyFileWithoutEditorKeyDefaultsIt() throws {
        // A settings JSON that predates the editor field must still decode.
        let json = """
        {"schemaVersion":2,"captureSavePath":"~/Pictures/ShareX","filenameTemplate":"x",
         "saveToDisk":true,"copyToClipboard":true,"showNotification":true,
         "hotkeys":{"fullscreen":null,"region":null,"window":null}}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.editor.annotateBeforeShare == false)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `scripts/remote.sh test`
Expected: FAIL — `AppSettings.editor` / `EditorSettings` not defined.

- [ ] **Step 3: Add EditorSettings to AppSettings**

In `Sources/SXCore/AppSettings.swift`, add the `EditorSettings` type above `AppSettings`:

```swift
public struct EditorSettings: Codable, Equatable, Sendable {
    public var annotateBeforeShare: Bool
    public init(annotateBeforeShare: Bool) {
        self.annotateBeforeShare = annotateBeforeShare
    }
    public static let `default` = EditorSettings(annotateBeforeShare: false)
}
```

Add the stored property to `AppSettings` (after `upload`):

```swift
    public var upload: UploadSettings
    public var editor: EditorSettings
```

Update the memberwise `init` — add the parameter (with a default so existing call sites keep compiling) and assignment:

```swift
    public init(schemaVersion: Int, captureSavePath: String, filenameTemplate: String,
                saveToDisk: Bool, copyToClipboard: Bool, showNotification: Bool,
                hotkeys: HotkeySettings, upload: UploadSettings,
                editor: EditorSettings = .default) {
        self.schemaVersion = schemaVersion
        self.captureSavePath = captureSavePath
        self.filenameTemplate = filenameTemplate
        self.saveToDisk = saveToDisk
        self.copyToClipboard = copyToClipboard
        self.showNotification = showNotification
        self.hotkeys = hotkeys
        self.upload = upload
        self.editor = editor
    }
```

Update the tolerant `init(from:)` — add after the `upload` line:

```swift
        upload = try c.decodeIfPresent(UploadSettings.self, forKey: .upload) ?? .disabled
        editor = try c.decodeIfPresent(EditorSettings.self, forKey: .editor) ?? .default
```

Add `editor` to `CodingKeys`:

```swift
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, captureSavePath, filenameTemplate, saveToDisk,
             copyToClipboard, showNotification, hotkeys, upload, editor
    }
```

Add `editor: .default` to the `.default` static (after `upload: .disabled`):

```swift
        upload: .disabled,
        editor: .default
    )
```

- [ ] **Step 4: Run the settings test to verify it passes**

Run: `scripts/remote.sh test`
Expected: PASS (all `EditorSettingsTests`); other `SXCoreTests` remain green.

- [ ] **Step 5: Add the gate to CaptureCoordinator**

In `Sources/SXApp/CaptureCoordinator.swift`:

Add a stored property and inject the presenter. Change the property block (after `historyStore`):

```swift
    private let historyStore: HistoryStore?
    private let editorPresenter: EditorPresenting?
```

Update `init` to accept it (defaulted to nil so tests/CLI paths that don't annotate stay simple):

```swift
    init(settingsStore: SettingsStore, effects: AppPipelineEffects,
         uploadService: UploadService, historyStore: HistoryStore?,
         editorPresenter: EditorPresenting? = nil) {
        self.settingsStore = settingsStore
        self.effects = effects
        self.uploadService = uploadService
        self.historyStore = historyStore
        self.editorPresenter = editorPresenter
    }
```

Replace the body of `deliver(image:appName:)` (currently lines ~140–162) with a gate that delegates to a new private `finish`:

```swift
    @discardableResult
    func deliver(image: CGImage, appName: String?) -> Bool {
        let (settings, _) = settingsStore.loadOrDefault()
        if settings.editor.annotateBeforeShare, let presenter = editorPresenter {
            presenter.present(image: image) { [weak self] edited in
                guard let self else { return }
                guard let edited else {
                    AppLog.log("Editor cancelled; capture discarded before save")
                    return
                }
                self.finish(image: edited, appName: appName)
            }
            return true
        }
        return finish(image: image, appName: appName)
    }

    /// Encodes the (possibly edited) image and runs the after-capture chain.
    /// Preserves the local-first invariant: disk save precedes any upload.
    @discardableResult
    private func finish(image: CGImage, appName: String?) -> Bool {
        guard let png = ImageEncoder.png(from: image) else {
            reportFailure(DeliveryError.pngEncodingFailed)
            return false
        }
        let artifact = CaptureArtifact(pngData: png, width: image.width, height: image.height,
                                       capturedAt: Date(), appName: appName)
        // Settings are reloaded fresh here (not the launch-time snapshot) so hand-edits
        // to settings.json take effect on the next capture; per-capture reload
        // deliberately ignores the load-issue channel (already reported at launch).
        let (settings, _) = settingsStore.loadOrDefault()
        do {
            let result = try AfterCapturePipeline(settings: settings, effects: effects)
                .process(artifact)
            AppLog.log("Capture delivered: \(result.savedURL?.path ?? "clipboard only")")
            recordAndMaybeUpload(settings: settings, savedURL: result.savedURL,
                                 pngData: png, capturedAt: artifact.capturedAt)
            return true
        } catch {
            reportFailure(error)
            return false
        }
    }
```

- [ ] **Step 6: Wire the presenter and menu toggle in AppDelegate**

In `Sources/SXApp/AppDelegate.swift`:

Add a stored property (after `historyWindow`):

```swift
    private var historyWindow: HistoryWindowController?
    private let editorWindow = EditorWindowController()
```

Pass it into the coordinator (in `applicationDidFinishLaunching`, update the `CaptureCoordinator(...)` init call):

```swift
        let coordinator = CaptureCoordinator(settingsStore: store, effects: effects,
                                             uploadService: uploadService,
                                             historyStore: historyStore,
                                             editorPresenter: editorWindow)
```

Add the toggle menu item in `buildMenu()` — insert after the `uploadToggle` block, before the following `.separator()`:

```swift
        let annotateToggle = menuItem("Annotate Before Sharing", #selector(toggleAnnotateBeforeShare))
        annotateToggle.state = currentAnnotateBeforeShare() ? .on : .off
        menu.addItem(annotateToggle)
```

Add the reader and the action (next to `currentUploadAfterCapture()` / `toggleUploadAfterCapture()`):

```swift
    private func currentAnnotateBeforeShare() -> Bool {
        SettingsStore(fileURL: SettingsStore.defaultFileURL).loadOrDefault().0.editor.annotateBeforeShare
    }

    @objc private func toggleAnnotateBeforeShare() {
        let store = SettingsStore(fileURL: SettingsStore.defaultFileURL)
        var (settings, _) = store.loadOrDefault()
        settings.editor.annotateBeforeShare.toggle()
        do {
            try store.save(settings)
            AppLog.log("Annotate before sharing: \(settings.editor.annotateBeforeShare)")
        } catch {
            AppLog.log("Failed to save annotate-before-sharing toggle: \(error)")
        }
        rebuildMenu()
    }
```

- [ ] **Step 7: Verify build + tests**

Run: `scripts/remote.sh build && scripts/remote.sh test`
Expected: build clean; all tests pass (existing + new `EditorSettingsTests`).

- [ ] **Step 8: Commit**

```bash
git add Sources/SXCore/AppSettings.swift Sources/SXApp/CaptureCoordinator.swift Sources/SXApp/AppDelegate.swift Tests/SXCoreTests/EditorSettingsTests.swift
git commit -m "Gate capture pipeline through editor when annotate-before-sharing is on"
```

---

### Task 13: Docs — porting map + README

**Files:**
- Modify: `docs/porting-map.md`
- Modify: `README.md`
- Test: none (docs); verify claims against shipped code.

**Interfaces:** none.

- [ ] **Step 1: Add the SXAnnotate section to the porting map**

Append to `docs/porting-map.md` a new section mapping the M3a Swift types to their ShareX counterparts. Use the existing table format in that file. Include rows for: `SXAnnotate/Model/Annotation` → ShareX `Core/Annotations/Base/Annotation.cs` (value-type model vs. class hierarchy; z-order = list order); `SXAnnotate/Model/AnnotationShape` → the concrete `RectangleAnnotation`/`EllipseAnnotation`/`LineAnnotation`/`ArrowAnnotation`/`FreehandAnnotation` shapes (closed enum, single classic arrow style, straight segments in v1); `SXAnnotate/Geometry/Annotation+Geometry` → per-shape `HitTest`/`GetBounds`; `SXAnnotate/Geometry/Annotation+Handles` → `EditorCore` handle enumeration + resize; `SXAnnotate/History/AnnotationHistory` → `Core/History/EditorHistory.cs` (value snapshots vs. mementos; annotation-only, no canvas snapshots in M3a); `SXAnnotate/Rendering/AnnotationRenderer` → the unified CG render replacing ShareX's Avalonia per-control + `RenderTargetBitmap` hybrid; `SXAnnotate/Editor/EditorModel` → `Core/Editor/EditorCore.cs` pointer dispatch; `SXApp/EditorWindowController` + gate → ShareX `AfterCaptureTasks` "AnnotateImage". Note explicitly that rotation, curved segments, multiple arrow styles, shadows, and crop/text/effects/step-badges are deferred (crop/text/effects/badges to M3b).

- [ ] **Step 2: Update the README status and features**

In `README.md`:
- Change the **Status** line to reflect M3a: capture, upload, and an "annotate before sharing" editor with vector shapes (rectangle, ellipse, line, arrow, freehand), select/move/resize, and unlimited undo/redo.
- Add an **Editor** subsection under Features describing: the v1 vector toolset, non-destructive document, undo/redo, and that it is opt-in via the "Annotate Before Sharing" menu toggle (runs between capture and the save→clipboard→upload chain).
- Do not claim text, highlighter, blur, pixelate, step-number badges, or crop — those are M3b. Verify every claim against the shipped code before writing it.

- [ ] **Step 3: Commit**

```bash
git add docs/porting-map.md README.md
git commit -m "Document M3a editor in porting map and README"
```

---

## Self-Review

*(Author checklist against spec §3.2 and the milestone list.)*

**1. Spec coverage (§3.2 Editor):**
- "Non-destructive document: base image + ordered annotation list; export flattens via CoreGraphics" → Tasks 1 (model), 5 (`flatten`). ✅
- v1 toolset "select/move, rectangle, ellipse, line, arrow, freehand" → Tasks 3, 8 (interaction), 9–10 (UI). ✅ (crop, text, highlighter, blur, pixelate, step-number badges → **deferred to M3b** — stated in Global Constraints and the milestone split.)
- "unlimited undo/redo" → Task 4 (bounded to 50 mementos, matching ShareX's `MaxAnnotationMementos`; "unlimited" in the spec is contrasted with none — the 50-cap is the established ShareX behavior and is documented). ⚠️ Note the cap divergence for the reviewer.
- "Canvas: AppKit NSView + CoreGraphics (precise hit-testing, Retina rendering); SwiftUI inspector" → Tasks 5, 7, 9 (NSView + CG + fit transform), 10 (SwiftUI toolbar/inspector). ✅
- "ShareX's shape geometry/hit-test math ports nearly 1:1" → Tasks 2–3 mirror the per-shape math. ✅
- "Editor actions (Copy / Save / Upload) feed back into the pipeline" → M3a wires a single **Done** that flattens and runs the existing save→clipboard→upload chain via the gate; the **Copy/Save/Upload action split is deferred to M3b**. ⚠️ Partial — flagged for the reviewer and the milestone note.
- Spec §6 "Snapshot tests → pixel-diff against goldens" → Task 6. ✅
- Spec §2 local-first invariant → Task 12 (`finish` saves before upload; cancel discards before save). ✅

**2. Placeholder scan:** No "TBD"/"handle edge cases"/"similar to Task N" — every code step contains complete code. Task 6 Step 3 requires a one-time golden generation (a genuine bootstrap action with exact commands), not a placeholder. ✅

**3. Type consistency:** Verified names across tasks — `AnnotationShape` cases (`.rectangle(rect:)`, `.ellipse(rect:)`, `.line(start:end:)`, `.arrow(start:end:)`, `.freehand(points:)`) used identically in Tasks 1, 2, 3, 5, 8; `HandleKind` cases match between Tasks 3, 8, 9; `EditorModel` published names (`annotations`, `activeTool`, `strokeColor`, `strokeWidth`, `selectedID`, `canUndo`, `canRedo`, `selectedAnnotation`, `displayAnnotations`) match their uses in Tasks 9–10; `EditorPresenting.present(image:completion:)` matches between Tasks 11 and 12; `AnnotationRenderer.drawAnnotations`/`flatten` match Tasks 5, 9. ✅

**Two items to surface to the human before/at review** (both are M3a-vs-spec scope calls, already reflected in the M3a/M3b split): the undo cap (50, per ShareX) and the Copy/Save/Upload action split (M3a ships a single Done; the three-way split lands in M3b). Neither blocks M3a shipping as independently useful software.

## Mac Smoke Checklist (run after the final review, before finishing the branch)

Deploy with `scripts/remote.sh run`, then:
1. Enable **Annotate Before Sharing** from the menu (verify the checkmark toggles and persists across a relaunch).
2. Capture a region → the editor window opens showing the capture.
3. Draw each shape: rectangle, ellipse, line, arrow, freehand. Confirm each renders with the current stroke color/width.
4. Change stroke color and width; draw again; confirm the new style applies.
5. Switch to **Select**; click a shape (selection outline + handles appear); drag to move; drag a handle to resize.
6. **Undo** repeatedly back to the empty image; **Redo** forward. Confirm the buttons enable/disable correctly.
7. Select a shape and **Delete**; confirm it disappears and Undo restores it.
8. Click **Done** → confirm the annotated image is saved to `~/Pictures/ShareX`, copied to the clipboard, and (if an upload destination is active) uploaded with the URL on the clipboard.
9. Capture again and click **Cancel** (and separately, close via the red button) → confirm nothing is saved (intentional discard) and a log line records the cancel.
10. Turn **Annotate Before Sharing** off → capture → confirm the editor does not open and the capture flows straight through as before.
