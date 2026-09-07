import AppKit

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private var recording = false
    private var uploading = false
    private var uploadFailed = false

    init(menu: NSMenu) {
        // variableLength, not squareLength: the item shows an elapsed-time title while
        // recording, and squareLength pins the width to the menu bar's thickness.
        // Measured on macOS 26.6 — a 22pt square against 53pt of icon-plus-"0:07"
        // content, so the title was clipped to a sliver that rendered as a bare ":".
        // With no title the item is 33pt rather than 38pt, so the idle icon does not
        // get wider from this.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // macOS persists status-item visibility per autosave name: ⌘-dragging an
        // item off the bar writes "NSStatusItem Visible <name> = 0" and it stays
        // gone across relaunches. Name the slot so that pref is greppable, and
        // force visible — for a menu-bar-only app, an invisible item is the app
        // being gone, not a preference worth honoring.
        statusItem.autosaveName = "Lumeshot"
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: "Lumeshot")
            if button.image == nil {
                AppLog.log("Status item: SF Symbol camera.viewfinder unavailable — item would be blank")
                button.title = "◎"   // never ship an invisible, zero-content item
            }
        }
        statusItem.menu = menu
        logPlacement(reason: "created")
        // Layout happens after the run loop turns; the frame at init is not the
        // one the user sees. Log again once it has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.logPlacement(reason: "settled")
        }
    }

    /// Where the item actually landed. A zero or off-screen frame with
    /// isVisible == true means macOS dropped it — the notch/overflow case —
    /// as opposed to us never having created it.
    func logPlacement(reason: String) {
        let frame = statusItem.button?.window?.frame
        let screen = statusItem.button?.window?.screen?.frame
        let onScreen = (frame != nil && screen != nil) ? screen!.intersects(frame!) : false
        AppLog.log("Status item (\(reason)): isVisible=\(statusItem.isVisible) "
                   + "frame=\(frame.map { NSStringFromRect($0) } ?? "nil") "
                   + "screen=\(screen.map { NSStringFromRect($0) } ?? "nil") onScreen=\(onScreen) "
                   + "image=\(statusItem.button?.image != nil)")
    }

    func setMenu(_ menu: NSMenu) {
        statusItem.menu = menu
    }

    /// Swaps the menu-bar icon between idle (camera) and recording (red
    /// stop-circle) state. Clears the elapsed-time title on return to idle.
    func setRecording(_ recording: Bool) {
        self.recording = recording
        updateIcon()
        if !recording { statusItem.button?.title = "" }
    }

    func setUploadActivity(_ activity: UploadActivity) {
        uploading = !activity.running.isEmpty
        uploadFailed = activity.latest?.error != nil
        statusItem.button?.toolTip = activity.summary ?? "Lumeshot"
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        if recording {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = NSImage(systemSymbolName: "stop.circle.fill",
                                   accessibilityDescription: "Recording")?
                .withSymbolConfiguration(config)
        } else {
            button.image = NSImage(systemSymbolName: uploading ? "arrow.up.circle" : uploadFailed ? "exclamationmark.circle" : "camera.viewfinder",
                                   accessibilityDescription: uploading ? "Uploading" : uploadFailed ? "Upload failed" : "Lumeshot")
        }
    }

    /// Elapsed-time label shown next to the recording icon (e.g. "0:07").
    /// Pass nil to clear it. Kept short per the design note in the spec.
    func setTitle(_ s: String?) {
        statusItem.button?.title = s.map { " \($0)" } ?? ""
    }
}
