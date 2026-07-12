import AppKit
import SwiftUI
import SXAnnotate

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
    private var window: NSWindow?
    private var completion: (@MainActor (EditorResult?) -> Void)?
    private var finished = false

    func present(image: CGImage, completion: @escaping @MainActor (EditorResult?) -> Void) {
        // One session at a time; a new capture supersedes any stale window (Task 12
        // replaces this with a queue so concurrent multi-display captures each get a turn).
        if window != nil { finish(nil) }
        self.completion = completion
        self.finished = false

        let model = EditorModel(baseImage: image)
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
        callback?(result)
    }

    // Closing the window via the red button is a cancel (discard).
    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }
}
