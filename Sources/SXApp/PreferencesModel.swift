import SwiftUI
import SXCore

enum PreferencesTab: Hashable {
    case general, capture, hotkeys, uploads, recording
}

@MainActor
final class PreferencesModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var selectedTab: PreferencesTab = .general
    let destinations: DestinationsModel
    private let store: SettingsStore
    private let onChange: () -> Void
    private let applyHotkeys: (HotkeySettings) -> Void

    init(store: SettingsStore, credentials: CredentialStore, onChange: @escaping () -> Void,
        applyHotkeys: @escaping (HotkeySettings) -> Void) {
        self.store = store
        self.onChange = onChange
        self.applyHotkeys = applyHotkeys
        self.settings = store.loadOrDefault().0
        self.destinations = DestinationsModel(store: store, credentials: credentials, onChange: onChange)
    }

    /// Re-read settings from disk — mirrors DestinationsModel.reloadFromDisk /
    /// HistoryModel.reload. Called by PreferencesWindowController.show() on
    /// reuse so an out-of-band edit (hand-edited settings.json, or a change
    /// made in another window) is visible whenever Preferences is reopened.
    func reload() {
        settings = store.loadOrDefault().0
        destinations.reloadFromDisk()
    }
}
