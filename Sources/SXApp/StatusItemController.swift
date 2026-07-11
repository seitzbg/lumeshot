import AppKit

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem

    init(menu: NSMenu) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: "ShareX for Mac")
        }
        statusItem.menu = menu
    }

    func setMenu(_ menu: NSMenu) {
        statusItem.menu = menu
    }
}
