import AppKit
import SwiftUI
import LumeshotCore

@MainActor
final class HistoryWindowController {
    private var window: NSWindow?
    private var model: HistoryModel?
    private let store: HistoryStore
    private let settingsStore: SettingsStore

    init(store: HistoryStore, settingsStore: SettingsStore) {
        self.store = store
        self.settingsStore = settingsStore
    }

    func show() {
        if let window {
            model?.reload()   // pick up captures recorded since the window was last shown
            // Settings were snapshotted when the model was first built, so GIF
            // FPS / max width edited in Preferences would not reach the export
            // sheet until the app restarted.
            model?.recordingSettings = settingsStore.loadOrDefault().0.recording
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let recording = settingsStore.loadOrDefault().0.recording
        let model = HistoryModel(store: store, recordingSettings: recording, settingsStore: settingsStore)
        self.model = model
        let hosting = NSHostingController(rootView: HistoryView(model: model))
        let w = NSWindow(contentViewController: hosting)
        w.title = "History"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 780, height: 600))
        w.contentMinSize = NSSize(width: 700, height: 480)
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}
