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
        w.setContentSize(NSSize(width: 900, height: 640))
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
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
