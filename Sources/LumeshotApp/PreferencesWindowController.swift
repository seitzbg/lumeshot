import AppKit
import SwiftUI
import LumeshotCore

@MainActor
final class PreferencesWindowController {
    private var window: NSWindow?
    private var model: PreferencesModel?
    private let store: SettingsStore
    private let credentials: CredentialStore
    private let onChange: () -> Void
    private let applyHotkeys: (HotkeySettings) -> Void

    init(store: SettingsStore, credentials: CredentialStore, onChange: @escaping () -> Void,
        applyHotkeys: @escaping (HotkeySettings) -> Void) {
        self.store = store
        self.credentials = credentials
        self.onChange = onChange
        self.applyHotkeys = applyHotkeys
    }

    func show(selecting tab: PreferencesTab? = nil) {
        if let window {
            model?.reload()
            if let tab { model?.selectedTab = tab }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = PreferencesModel(store: store, credentials: credentials,
                                     onChange: onChange, applyHotkeys: applyHotkeys)
        if let tab { model.selectedTab = tab }
        self.model = model
        let hosting = NSHostingController(rootView: PreferencesView(model: model))
        let w = NSWindow(contentViewController: hosting)
        w.title = "Lumeshot Settings"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 560, height: 420))
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}
