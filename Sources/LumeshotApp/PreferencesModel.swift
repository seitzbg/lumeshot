import SwiftUI
import LumeshotCore

enum PreferencesTab: Hashable, CaseIterable {
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

    /// Load-mutate-save-notify: mirrors DestinationsModel.persist but for the
    /// non-upload slice of AppSettings, so General/Capture/Recording/Hotkeys
    /// edits here and Uploads-tab edits (routed through `destinations`) never
    /// clobber each other — each reloads the full file immediately before
    /// mutating and saving its own slice.
    ///
    /// The whole load-modify-save runs inside one `store.mutate` transaction.
    /// Separate `loadOrDefault` + `save` calls each took the lock individually but
    /// left the interval between them unguarded: the SSH host-key callback pins a
    /// fingerprint from a background thread mid-edit, and a preference save that
    /// had loaded the pre-pin settings would then write the stale copy back,
    /// dropping the pin so the next connection trusts a presented key afresh.
    func update(_ mutate: (inout AppSettings) -> Void) {
        do {
            settings = try store.mutate { mutate(&$0) }
            onChange()
        } catch {
            AppLog.log("Preferences: save failed: \(error)")
        }
    }

    /// Persists a hotkeys-only edit, then re-registers the global hotkeys
    /// immediately so the change takes effect without an app relaunch —
    /// hotkeys are the one setting AppDelegate caches at launch instead of
    /// re-reading fresh per use (exploration §3).
    func updateHotkeys(_ mutate: (inout HotkeySettings) -> Void) {
        update { mutate(&$0.hotkeys) }
        applyHotkeys(settings.hotkeys)
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
