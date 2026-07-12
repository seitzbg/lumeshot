import AppKit
import SXCapture

// Borderless windows refuse key status by default; we need it for Esc.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class RegionOverlaySession {
    private var windows: [NSWindow] = []
    private let displays: [FrozenDisplay]
    private let onComplete: @MainActor (CGImage?) -> Void
    private var finished = false

    init(displays: [FrozenDisplay], onComplete: @escaping @MainActor (CGImage?) -> Void) {
        self.displays = displays
        self.onComplete = onComplete
    }

    func begin() {
        // Activate first so the borderless overlay reliably takes keyboard focus
        // (this is a background LSUIElement app; without this the first invocation
        // can show an unfocused overlay that ignores Escape).
        NSApp.activate(ignoringOtherApps: true)
        for display in displays {
            let window = KeyableWindow(contentRect: display.screenFrame,
                                       styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = true
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            let view = RegionSelectionView(display: display) { [weak self] selection in
                self?.finish(display: display, selection: selection)
            }
            window.contentView = view
            window.acceptsMouseMovedEvents = true
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            windows.append(window)
        }
        NSCursor.crosshair.set()
    }

    /// selection is in view points (top-left origin); nil = cancelled.
    private func finish(display: FrozenDisplay, selection: CGRect?) {
        guard !finished else { return }
        finished = true
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()

        guard let selection else { onComplete(nil); return }
        let crop = CaptureGeometry.pixelCropRect(selection: selection, scale: display.scale,
                                                 imageWidth: display.image.width,
                                                 imageHeight: display.image.height)
        guard !crop.isEmpty else { onComplete(nil); return }
        guard let cropped = display.image.cropping(to: crop) else {
            AppLog.log("Region crop failed for rect \(crop)")
            onComplete(nil); return
        }
        onComplete(cropped)
    }
}

@MainActor
final class RegionSelectionView: NSView {
    private let display: FrozenDisplay
    private let onDone: (CGRect?) -> Void
    private var frozenImage: NSImage
    private var dragStart: CGPoint?
    private var current: CGPoint = .zero
    private var hasMouse = false

    // Flipped: view coords are top-left origin, matching the frozen image.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(display: FrozenDisplay, onDone: @escaping (CGRect?) -> Void) {
        self.display = display
        self.onDone = onDone
        self.frozenImage = NSImage(cgImage: display.image,
                                   size: display.screenFrame.size)
        super.init(frame: CGRect(origin: .zero, size: display.screenFrame.size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        // Frozen desktop, dimmed.
        frozenImage.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()

        let selection = dragStart.map { CaptureGeometry.normalizedRect(from: $0, to: current) }

        // Selected area shown undimmed.
        if let selection {
            NSGraphicsContext.current?.saveGraphicsState()
            selection.clip()
            frozenImage.draw(in: bounds)
            NSGraphicsContext.current?.restoreGraphicsState()
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: selection)
            outline.lineWidth = 1
            outline.stroke()
            drawLabel("\(Int(selection.width * display.scale)) × \(Int(selection.height * display.scale))",
                      at: CGPoint(x: selection.minX, y: selection.maxY + 6))
        }

        if hasMouse {
            drawCrosshair()
            drawLoupe()
        }
    }

    private func drawCrosshair() {
        NSColor.white.withAlphaComponent(0.8).setStroke()
        let h = NSBezierPath()
        h.move(to: CGPoint(x: 0, y: current.y))
        h.line(to: CGPoint(x: bounds.maxX, y: current.y))
        let v = NSBezierPath()
        v.move(to: CGPoint(x: current.x, y: 0))
        v.line(to: CGPoint(x: current.x, y: bounds.maxY))
        h.lineWidth = 1; v.lineWidth = 1
        h.stroke(); v.stroke()
    }

    /// 8x loupe of the frozen image around the cursor, offset to stay visible.
    private func drawLoupe() {
        let loupeSize: CGFloat = 120
        let zoom: CGFloat = 8
        let srcSide = loupeSize / zoom * display.scale
        let src = CGRect(x: current.x * display.scale - srcSide / 2,
                         y: current.y * display.scale - srcSide / 2,
                         width: srcSide, height: srcSide)
        guard let sub = display.image.cropping(to: src) else { return }

        var origin = CGPoint(x: current.x + 24, y: current.y + 24)
        if origin.x + loupeSize > bounds.maxX { origin.x = current.x - 24 - loupeSize }
        if origin.y + loupeSize > bounds.maxY { origin.y = current.y - 24 - loupeSize }
        let dest = CGRect(origin: origin, size: CGSize(width: loupeSize, height: loupeSize))

        NSGraphicsContext.current?.imageInterpolation = .none   // crisp pixels
        NSImage(cgImage: sub, size: dest.size).draw(in: dest)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: dest)
        border.lineWidth = 2
        border.stroke()
        drawLabel(String(format: "%.0f, %.0f", current.x * display.scale, current.y * display.scale),
                  at: CGPoint(x: dest.minX, y: dest.maxY + 4))
    }

    private func drawLabel(_ text: String, at point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7),
        ]
        NSAttributedString(string: " \(text) ", attributes: attrs).draw(at: point)
    }

    override func mouseEntered(with event: NSEvent) { hasMouse = true }
    override func mouseExited(with event: NSEvent) { hasMouse = false; needsDisplay = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeAlways, .mouseMoved,
                                                 .mouseEnteredAndExited],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hasMouse = true
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        current = dragStart!
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        current = convert(event.locationInWindow, from: nil)
        let selection = CaptureGeometry.normalizedRect(from: start, to: current)
        if selection.width >= 4 && selection.height >= 4 {
            onDone(selection)
        } else {
            // A click or sub-4pt slip is not a selection; keep the overlay up
            // (only Escape cancels) so a stray click doesn't dismiss it.
            dragStart = nil
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Escape
            onDone(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
