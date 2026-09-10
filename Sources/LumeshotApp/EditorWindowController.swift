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
        // Size the window to the capture so the image opens at ~1:1, scaled to fit when it
        // is larger than the display. The window stays freely resizable from here.
        w.setContentSize(Self.contentSize(forCapture: next.image))
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }

    /// Chrome that surrounds the canvas: the left tool rail + its divider, and the top
    /// bar + its divider. Subtracted from / added to the image's on-screen size so the
    /// canvas ends up showing the capture at 1:1 when the window fits it.
    private static let railWidth: CGFloat = 190 + 1
    private static let topBarHeight: CGFloat = 44 + 1

    /// Window content size for a capture, using the target screen's backing scale to turn
    /// the image's pixels into on-screen points. Convenience over the pure `editorContentSize`.
    static func contentSize(forCapture image: CGImage, screen: NSScreen? = .main) -> NSSize {
        editorContentSize(imagePixelSize: CGSize(width: image.width, height: image.height),
                          backingScale: screen?.backingScaleFactor ?? 2,
                          visibleFrame: screen?.visibleFrame.size)
    }

    /// Pure size math (no screen dependency, so it is unit-testable): the capture at 1:1
    /// plus the surrounding chrome, capped to 90% of the visible frame for large captures,
    /// and floored at the usable minimum for small ones.
    static func editorContentSize(imagePixelSize: CGSize,
                                  backingScale: CGFloat,
                                  visibleFrame: CGSize?) -> NSSize {
        let scale = max(backingScale, 1)
        var width = imagePixelSize.width / scale + railWidth
        var height = imagePixelSize.height / scale + topBarHeight
        if let visible = visibleFrame {
            width = min(width, visible.width * 0.9)
            height = min(height, visible.height * 0.9)
        }
        return NSSize(width: max(760, width), height: max(480, height))
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
