import AppKit
import SXCapture

/// Parallel to `RegionOverlaySession`, but for recording: returns the selected
/// display + the raw selection rect (view points, top-left origin) instead of
/// a cropped image, since the caller needs the live display to build an
/// `SCContentFilter` for an in-progress `SCStream`, not a frozen pixel crop.
/// Reuses `RegionSelectionView`/`KeyableWindow` (widened to internal above).
@MainActor
final class RecordingRegionSession {
    private var windows: [NSWindow] = []
    private let displays: [FrozenDisplay]
    private let onComplete: @MainActor ((display: FrozenDisplay, rect: CGRect)?) -> Void
    private var finished = false

    init(displays: [FrozenDisplay],
        onComplete: @escaping @MainActor ((display: FrozenDisplay, rect: CGRect)?) -> Void) {
        self.displays = displays
        self.onComplete = onComplete
    }

    func begin() {
        // Activate first so the borderless overlay reliably takes keyboard focus
        // (background LSUIElement app; without this the first invocation can show
        // an unfocused overlay that ignores Escape). Same as RegionOverlaySession.
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
        onComplete((display: display, rect: selection))
    }
}
