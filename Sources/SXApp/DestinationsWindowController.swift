import AppKit
import SwiftUI
import SXCore

@MainActor
final class DestinationsWindowController {
    private var window: NSWindow?
    private let store: SettingsStore
    private let credentials: CredentialStore
    private let onChange: () -> Void

    init(store: SettingsStore, credentials: CredentialStore, onChange: @escaping () -> Void) {
        self.store = store
        self.credentials = credentials
        self.onChange = onChange
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = DestinationsModel(store: store, credentials: credentials, onChange: onChange)
        let hosting = NSHostingController(rootView: DestinationsView(model: model))
        let w = NSWindow(contentViewController: hosting)
        w.title = "Manage Destinations"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 480, height: 440))
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}
