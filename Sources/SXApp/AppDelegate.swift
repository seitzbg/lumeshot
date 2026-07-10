import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(menu: buildMenu())
        NSLog("ShareX for Mac launched (bundle: \(Bundle.main.bundleIdentifier ?? "none"))")
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Capture Region", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Capture Window", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Capture Full Screen", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ShareX for Mac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }
}
