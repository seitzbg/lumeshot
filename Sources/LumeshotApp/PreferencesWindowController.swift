import AppKit
import SwiftUI
import LumeshotCore

@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: PreferencesModel?
    private let store: SettingsStore
    private let credentials: CredentialStore
    private let onChange: () -> Void
    private let applyHotkeys: (HotkeySettings) -> Void
    private var previousActivationPolicy: NSApplication.ActivationPolicy?

    var isOpen: Bool { previousActivationPolicy != nil }

    init(store: SettingsStore, credentials: CredentialStore, onChange: @escaping () -> Void,
        applyHotkeys: @escaping (HotkeySettings) -> Void) {
        self.store = store
        self.credentials = credentials
        self.onChange = onChange
        self.applyHotkeys = applyHotkeys
        super.init()
    }

    func show(selecting tab: PreferencesTab? = nil) {
        // Stay in the Dock/app switcher while Settings is open, including when
        // minimized or behind another app. Repeated shows must not overwrite
        // the policy we restore when the window actually closes.
        if previousActivationPolicy == nil {
            previousActivationPolicy = NSApp.activationPolicy()
        }
        NSApp.setActivationPolicy(.regular)
        if let window {
            model?.reload()
            if let tab { model?.selectedTab = tab }
            NSApp.activate(ignoringOtherApps: true)
            if window.isMiniaturized { window.deminiaturize(nil) }
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
        w.setContentSize(NSSize(width: 820, height: 620))
        w.contentMinSize = NSSize(width: 760, height: 560)
        let restoredFrame = w.setFrameUsingName("LumeshotSettings")
        w.setFrameAutosaveName("LumeshotSettings")
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        NSApp.activate(ignoringOtherApps: true)
        if !restoredFrame { w.center() }
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window,
              let policy = previousActivationPolicy else { return }
        previousActivationPolicy = nil
        NSApp.setActivationPolicy(policy)
    }
}
