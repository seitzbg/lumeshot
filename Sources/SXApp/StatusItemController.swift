import AppKit

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem

    init(menu: NSMenu) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: "Lumeshot")
        }
        statusItem.menu = menu
    }

    func setMenu(_ menu: NSMenu) {
        statusItem.menu = menu
    }

    /// Swaps the menu-bar icon between idle (camera) and recording (red
    /// stop-circle) state. Clears the elapsed-time title on return to idle.
    func setRecording(_ recording: Bool) {
        guard let button = statusItem.button else { return }
        if recording {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = NSImage(systemSymbolName: "stop.circle.fill",
                                   accessibilityDescription: "Recording")?
                .withSymbolConfiguration(config)
        } else {
            button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: "Lumeshot")
            button.title = ""
        }
    }

    /// Elapsed-time label shown next to the recording icon (e.g. "0:07").
    /// Pass nil to clear it. Kept short per the design note in the spec.
    func setTitle(_ s: String?) {
        statusItem.button?.title = s.map { " \($0)" } ?? ""
    }
}
