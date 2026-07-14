import AppKit
import LumeshotCapture

// Full-screen transparent overlays; hovering highlights the window under the
// cursor, click picks it, Esc cancels.
@MainActor
final class WindowPickerSession {
    private var windows: [NSWindow] = []
    private let candidates: [WindowCandidate]
    private let onPick: @MainActor (WindowCandidate?) -> Void
    private var finished = false

    init(candidates: [WindowCandidate], onPick: @escaping @MainActor (WindowCandidate?) -> Void) {
        self.candidates = candidates
        self.onPick = onPick
    }

    func begin() {
        guard !candidates.isEmpty else { onPick(nil); return }
        // Activate first so the borderless overlay reliably takes keyboard focus
        // (this is a background LSUIElement app; without this the first invocation
        // can show an unfocused overlay that ignores Escape).
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let window = PickerWindow(contentRect: screen.frame, styleMask: .borderless,
                                      backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            let view = WindowPickerView(candidates: candidates, screen: screen) { [weak self] pick in
                self?.finish(pick)
            }
            window.contentView = view
            window.acceptsMouseMovedEvents = true
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            windows.append(window)
        }
    }

    private func finish(_ pick: WindowCandidate?) {
        guard !finished else { return }
        finished = true
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        onPick(pick)
    }
}

private final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class WindowPickerView: NSView {
    private let candidates: [WindowCandidate]
    private let screen: NSScreen
    private let onDone: (WindowCandidate?) -> Void
    private var hovered: WindowCandidate?

    init(candidates: [WindowCandidate], screen: NSScreen,
         onDone: @escaping (WindowCandidate?) -> Void) {
        self.candidates = candidates
        self.screen = screen
        self.onDone = onDone
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var acceptsFirstResponder: Bool { true }

    /// CG global (top-left origin) -> this view's coordinates (bottom-left origin).
    private func viewRect(fromCGGlobal rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let appKit = CaptureGeometry.appKitRect(fromCGGlobal: rect, primaryHeight: primaryHeight)
        return CGRect(x: appKit.origin.x - screen.frame.origin.x,
                      y: appKit.origin.y - screen.frame.origin.y,
                      width: appKit.width, height: appKit.height)
    }

    private func candidateAt(viewPoint p: CGPoint) -> WindowCandidate? {
        // candidates are sorted area-descending; last hit = smallest window.
        candidates.last { viewRect(fromCGGlobal: $0.frame).contains(p) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        guard let hovered else { return }
        let rect = viewRect(fromCGGlobal: hovered.frame)
        NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
        rect.fill()
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 3
        path.stroke()

        let label = "\(hovered.appName ?? "?") — \(hovered.title ?? "Untitled")"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7),
        ]
        NSAttributedString(string: " \(label) ", attributes: attrs)
            .draw(at: CGPoint(x: rect.minX + 8, y: rect.maxY - 28))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeAlways, .mouseMoved],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = candidateAt(viewPoint: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onDone(candidateAt(viewPoint: convert(event.locationInWindow, from: nil)))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Escape
            onDone(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
