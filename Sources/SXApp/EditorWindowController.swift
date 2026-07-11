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
    private var completion: (@MainActor (CGImage?) -> Void)?
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
