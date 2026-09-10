import AppKit
import SwiftUI
import LumeshotAnnotate

/// The action the user chose in the editor. Copy = clipboard-only (ephemeral);
/// Save = disk + history; Upload = disk + history + upload.
enum EditorAction: Sendable { case copy, save, upload }

/// The editor's outcome: the chosen action plus the flattened image.
struct EditorResult { let action: EditorAction; let image: CGImage }   // MainActor-confined; not Sendable (would over-constrain CGImage across SDKs)

@MainActor
protocol EditorPresenting {
    /// Presents the editor for `image`. Calls `completion` once: an `EditorResult`
    /// (Copy/Save/Upload) on finish, or nil if the user cancelled/closed without finishing.
    func present(image: CGImage, completion: @escaping @MainActor (EditorResult?) -> Void)
}

@MainActor
final class EditorWindowController: NSObject, EditorPresenting, NSWindowDelegate {
    private struct PendingPresentation {
        let image: CGImage
        let completion: (@MainActor (EditorResult?) -> Void)
    }

    private var window: NSWindow?
    private var completion: (@MainActor (EditorResult?) -> Void)?
    private var finished = false

    // FIFO queue so concurrent captures (e.g. one per display in a multi-display
    // fullscreen grab) each get their own editor turn instead of superseding.
    private var queue: [PendingPresentation] = []
    private var isPresenting = false

    func present(image: CGImage, completion: @escaping @MainActor (EditorResult?) -> Void) {
        queue.append(PendingPresentation(image: image, completion: completion))
        presentNextIfIdle()
    }

    private func presentNextIfIdle() {
        guard !isPresenting, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        isPresenting = true
        self.completion = next.completion
        self.finished = false

        let model = EditorModel(baseImage: next.image)
        let view = EditorView(
            model: model,
            onAction: { [weak self] result in self?.finish(result) },
            onCancel: { [weak self] in self?.finish(nil) })
        let hosting = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: hosting)
        w.title = "Edit Capture"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Set the floor explicitly rather than leaning on NSHostingController to derive
        // it from the SwiftUI min frame (which it only does asynchronously, after the
        // window is already on screen).
        w.contentMinSize = NSSize(width: 760, height: 480)
        w.setContentSize(Self.defaultContentSize())
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        // Remember the size/position the user picks and restore it for the next capture
        // and the next launch, so a one-time resize sticks. Applied after `center()` so a
        // saved frame wins; the centred default stands the first time.
        w.setFrameAutosaveName("LumeshotEditorWindow")
        w.makeKeyAndOrderFront(nil)
    }

    /// A generous default editor size — big enough to mark up a capture without an
    /// immediate resize — capped so it never exceeds the visible screen.
    static func defaultContentSize() -> NSSize {
        let preferred = NSSize(width: 1200, height: 780)
        guard let visible = NSScreen.main?.visibleFrame.size else { return preferred }
        return NSSize(width: max(760, min(preferred.width, visible.width * 0.9)),
                      height: max(480, min(preferred.height, visible.height * 0.9)))
    }

    private func finish(_ result: EditorResult?) {
        guard !finished else { return }
        finished = true
        let callback = completion
        completion = nil
        window?.delegate = nil
        window?.close()
        window = nil
        isPresenting = false
        callback?(result)
        presentNextIfIdle()   // show the next queued capture, if any
    }

    // Closing the window via the red button is a cancel (discard).
    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }
}
