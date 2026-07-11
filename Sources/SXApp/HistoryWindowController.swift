import AppKit
import SwiftUI
import SXCore

@MainActor
final class HistoryWindowController {
    private var window: NSWindow?
    private let store: HistoryStore

    init(store: HistoryStore) { self.store = store }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = HistoryModel(store: store)
        let hosting = NSHostingController(rootView: HistoryView(model: model))
        let w = NSWindow(contentViewController: hosting)
        w.title = "History"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 560, height: 460))
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}
