# Preferences Window (Tabbed, Live Hotkey Recorder) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a dedicated, tabbed Preferences window for Lumeshot (General / Capture / Hotkeys / Uploads / Recording), opened via a new "Settings… ⌘," status-bar menu item, with a live global-hotkey recorder that re-registers Carbon hotkeys immediately on edit, and with the existing standalone "Manage Destinations…" window folded into the new Uploads tab without touching its Keychain-first secrets flow. Every field this plan exposes already exists in `AppSettings` — this is additive UI only, no settings-schema bump.

**Architecture:** `PreferencesWindowController` (`Sources/SXApp/PreferencesWindowController.swift`) copies the `HistoryWindowController`/`DestinationsWindowController` single-retained-window pattern verbatim (`private var window: NSWindow?`, `isReleasedWhenClosed = false`, reuse-and-reload on `show()`), hosting a SwiftUI `PreferencesView` via `NSHostingController`. `PreferencesModel` (`Sources/SXApp/PreferencesModel.swift`, `@MainActor final class: ObservableObject`) owns `@Published var settings: AppSettings` (loaded fresh via `SettingsStore.loadOrDefault()`) and a `load-mutate-save-notify` method `update(_:)` that mirrors `DestinationsModel.persist` exactly, so both models can independently edit the same `settings.json` without racing or clobbering each other's slice. `PreferencesModel` also owns the Uploads tab's `DestinationsModel` (constructed once, in `init`, with the same `store`/`credentials`/`onChange`) so the whole window shares one load-mutate-save discipline. `PreferencesView` (`Sources/SXApp/PreferencesView.swift`) is a SwiftUI `TabView` with 5 `.tabItem` tabs, each a small private subview bound to `model` through inline `Binding(get:set:)` wrappers that call `model.update { $0.<field> = newValue }`. `AppDelegate.buildMenu()` gains a "Settings… ⌘," item wired to a new `@objc showPreferences()`, and the existing "Manage Destinations…" item's handler is repointed to open Preferences on the Uploads tab instead of the old standalone `DestinationsWindowController` (that controller and its file are left in place, unused, per the contract's own default). Every General/Capture/Uploads/Recording edit is live the instant `store.save(...)` returns, because every consumer in the app re-reads settings fresh per operation (confirmed live in exploration §2) — `onChange` just calls `AppDelegate.rebuildMenu()` so status-bar checkmarks stay in sync. Hotkeys are the one exception: `AppDelegate.registerHotkeys(_:)` is called exactly once at launch and cached in `self.hotkeys`, so a Preferences hotkey edit needs an explicit re-apply step — `AppDelegate.reapplyHotkeys(_:)` does `hotkeys?.unregisterAll(); hotkeys = nil; registerHotkeys(config)`, mirroring the app's own launch sequence and avoiding the Carbon-registration leak that skipping `unregisterAll()` would cause (`HotkeyManager` has no per-hotkey unregister — exploration §3). The Hotkeys tab's live recorder (`HotkeyRecorderField`, `Sources/SXApp/HotkeyRecorderField.swift`) is a plain SwiftUI view that installs a local `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` monitor while "recording," converting the captured `event.keyCode`/`event.modifierFlags` into a `HotkeyCombo` via pure formatting/mapping helpers added to `Sources/SXCore/HotkeyFormatting.swift` (`HotkeyCombo.displayString`, `HotkeyModifiers.carbonMask(fromAppKit:)`/`.appKitRaw(fromCarbon:)`) — the only piece of this feature with a CI unit-test target, since `SXApp` is an executable target with no test target.

**Tech Stack:** Swift 6.0 (strict concurrency), SwiftPM (`swift-tools-version: 6.0`), macOS 15+, AppKit + SwiftUI interop (`NSHostingController`, `TabView`, `NSOpenPanel`, `NSEvent` local monitors), Carbon `HIToolbox` hotkey registration (unchanged, existing `HotkeyManager`). swift-testing (`@Test`/`#expect`/`@Suite`, zero XCTest) for the one CI-tested task. Build/test on a remote Mac via `scripts/remote.sh {build,test}`.

## Global Constraints

*Every task's requirements implicitly include this section. Values are copied verbatim from the ratified architecture contract (`/tmp/prefs-contract.md`) and cross-checked live against `/home/bseitz/git/sharex-mac` @ branch `preferences-ui` (exploration report: `.superpowers/sdd/prefs-exploration.md`).*

- Swift 6.0 strict concurrency is the CI gate. All UI is `@MainActor`. No settings-schema bump — every field this plan exposes already exists in `AppSettings`/`HotkeySettings`/`RecordingSettings`/`UploadSettings`; this is additive UI only.
- Secrets stay in the Keychain. The Uploads tab reuses `DestinationsModel`'s existing Keychain-first add/remove/purge flow (`Sources/SXApp/DestinationsView.swift`) completely unchanged — do not move a secret into `settings.json` or regress the invariant.
- Local-first/fail-loud unchanged. No AI-attribution anywhere (commits, docs, comments). No emoji beyond UI glyphs (SF Symbols in `Label(...)`/`Image(systemName:)` are fine; they are not text emoji).
- Reuse existing patterns; do not rename `SX*` targets or touch the bundle ID `org.sharexmac.app` (`Resources/Info.plist`: `CFBundleExecutable SXApp`, `CFBundleIdentifier org.sharexmac.app`, `CFBundleName`/`CFBundleDisplayName` `Lumeshot`).
- **NO `SXAppTests` target** (established precedent — see `Package.swift`: `SXApp` is `.executableTarget(name: "SXApp", ...)` with `Sources/SXApp/main.swift`, which a test target cannot `@testable import`). Tasks 1–5 and 7 (all in `SXApp`) are therefore **build-only + Mac smoke**: their steps run `scripts/remote.sh build` then `scripts/remote.sh test` (the full existing suite — no new tests, no `Tests/SXAppTests/` files, no invented UI unit tests) plus a smoke note pointing at `docs/smoke-prefs.md` (written in Task 8). The **only** CI-unit-tested task is **Task 6** (`Sources/SXCore/HotkeyFormatting.swift` / `Tests/SXCoreTests/HotkeyFormattingTests.swift`).
- **Build/test loop (`scripts/remote.sh`, verified live):** `build` → `ssh $MAC_HOST "cd $MAC_DIR && swift build"`; `test` → `... && swift test`; `run` → release build + `scripts/bundle.sh` + relaunch `dist/Lumeshot.app`; `ssh '<cmd>'` runs an arbitrary command in the synced tree. `build`/`test` do not bundle or relaunch the app.
- **Current-state facts (ground truth, verified live):**
  - `SettingsStore` (`Sources/SXCore/SettingsStore.swift`) is a plain `struct SettingsStore: Sendable { public let fileURL: URL }` — no cached in-memory `AppSettings`, no `ObservableObject`. `loadOrDefault() -> (AppSettings, SettingsLoadIssue?)` and `save(_ settings: AppSettings) throws` (JSON, `[.prettyPrinted, .sortedKeys]`, atomic write). `SettingsStore.defaultFileURL` = `~/Library/Application Support/ShareX-Mac/settings.json`.
  - `AppSettings.default` (`Sources/SXCore/AppSettings.swift:103-119`): `hotkeys: HotkeySettings(fullscreen: HotkeyCombo(keyCode: 20, modifiers: 2560), region: HotkeyCombo(keyCode: 21, modifiers: 2560), window: HotkeyCombo(keyCode: 23, modifiers: 2560), record: HotkeyCombo(keyCode: 22, modifiers: 2560))` — Carbon `optionKey(2048) | shiftKey(512) = 2560`; `kVK_ANSI_3=20, _4=21, _5=23, _6=22` (comment already in source). `captureSavePath = "~/Pictures/ShareX"`, `filenameTemplate = "Screenshot_%y-%mo-%d_%h-%mi-%s"`, `saveToDisk/copyToClipboard/showNotification = true`.
  - `RecordingSettings` (`Sources/SXCore/RecordingSettings.swift`): `systemAudio: Bool = false`, `videoCodec: VideoCodec = .h264` (`enum VideoCodec: String, Codable, Equatable, Sendable { case h264, hevc }` — **not** `Hashable`), `gifFPS: Int = 15`, `gifMaxWidth: Int? = 640`.
  - `UploadSettings` (`Sources/SXCore/Upload/UploadSettings.swift`): `uploadAfterCapture: Bool`, `activeDestinationID: String?`, `destinations: [UploadDestination]`.
  - `DestinationsModel` (`Sources/SXApp/DestinationsView.swift:5-150`): `@MainActor final class: ObservableObject { @Published var settings: UploadSettings }`, `init(store: SettingsStore, credentials: CredentialStore, onChange: @escaping () -> Void)`, private `persist(_ mutate: (inout AppSettings) -> Void) -> Bool` (load-mutate-save-refresh-notify), `reloadFromDisk()`.
  - `HotkeyManager` (`Sources/SXApp/HotkeyManager.swift`): `register(_ combo: HotkeyCombo, handler: @escaping @MainActor () -> Void)`, `unregisterAll()` (no per-hotkey unregister). `AppDelegate.registerHotkeys(_ config: HotkeySettings)` creates one `HotkeyManager`, assigns `self.hotkeys`, registers all 4 non-nil combos; called once at the end of `applicationDidFinishLaunching`.
  - `AppDelegate` (`Sources/SXApp/AppDelegate.swift`) already has `recordingStartedAt`/`elapsedLabel(since:)` (M5b P1, already landed on this branch) — not part of this plan, just confirming the file's current shape before editing it.
  - Window-controller pattern (`HistoryWindowController`/`DestinationsWindowController`): `private var window: NSWindow?`; `show()` reuses+reloads if `window` is non-nil, else constructs `<X>Model` → `NSHostingController(rootView: <X>View(model:))` → `NSWindow(contentViewController:)` with `styleMask [.titled, .closable, .miniaturizable, .resizable]`, `isReleasedWhenClosed = false`, `.center()`, `.makeKeyAndOrderFront(nil)`.

## File Structure

**New:** `Sources/SXApp/PreferencesWindowController.swift`, `Sources/SXApp/PreferencesModel.swift`, `Sources/SXApp/PreferencesView.swift`, `Sources/SXApp/HotkeyRecorderField.swift`, `Sources/SXCore/HotkeyFormatting.swift`, `Tests/SXCoreTests/HotkeyFormattingTests.swift`, `docs/smoke-prefs.md`.
**Modified:** `Sources/SXApp/AppDelegate.swift`, `Sources/SXApp/DestinationsView.swift`.

---
### Task 1: `PreferencesWindowController` + tabbed shell + menu item

**Files:**
- Create: `Sources/SXApp/PreferencesWindowController.swift`
- Create: `Sources/SXApp/PreferencesModel.swift`
- Create: `Sources/SXApp/PreferencesView.swift`
- Modify: `Sources/SXApp/AppDelegate.swift`
- Test: none (SXApp has no test target). Build-only + Mac smoke (deferred to `docs/smoke-prefs.md`, Task 8).

**Interfaces:**
- Produces: `PreferencesWindowController.init(store: SettingsStore, credentials: CredentialStore, onChange: @escaping () -> Void, applyHotkeys: @escaping (HotkeySettings) -> Void)` and `func show(selecting tab: PreferencesTab? = nil)`.
- Produces: `PreferencesModel.init(store: SettingsStore, credentials: CredentialStore, onChange: @escaping () -> Void, applyHotkeys: @escaping (HotkeySettings) -> Void)`, `@Published var settings: AppSettings`, `@Published var selectedTab: PreferencesTab`, `let destinations: DestinationsModel`, `func reload()`.
- Produces: `enum PreferencesTab: Hashable { case general, capture, hotkeys, uploads, recording }` and `struct PreferencesView: View`.
- Produces on `AppDelegate`: `private var preferencesWindow: PreferencesWindowController?`, `@objc private func showPreferences()`, `private func reapplyHotkeys(_ config: HotkeySettings)`.
- Consumes: `SettingsStore`, `CredentialStore`, `KeychainCredentialStore()` (all already used identically by `destinationsWindow`'s construction, `Sources/SXApp/AppDelegate.swift:54-56`).
- **Ambiguity resolution #1 (ground truth wins):** the contract describes `preferencesWindow` as "lazy, mirrors `destinationsWindow`/`historyWindow`" — but those two differ (`destinationsWindow` is constructed eagerly in `applicationDidFinishLaunching`; `historyWindow` is constructed lazily on first `showHistory()`). This plan mirrors **`destinationsWindow`'s eager construction** (constructed right next to it, using the same `store`/`credentials`/`onChange`, plus a trivial `applyHotkeys` closure referencing `self`) rather than lazy-on-first-use, since all its dependencies are already in scope at that call site and there's no benefit to deferring it. `PreferencesWindowController.show()` itself still lazily constructs the `PreferencesModel`/window on first call, exactly like both existing controllers.
- **Ambiguity resolution #2:** the contract describes `reapplyHotkeys(_:)` as a "stub wired but not yet used" in Task 1, fully "added" in Task 7's description. Since its correct 3-line body (`unregisterAll()` → `hotkeys = nil` → `registerHotkeys(config)`) is already fully specified by exploration §3 with zero unknowns, this plan implements it **in full in this task** — "stub" is satisfied by it being wired into the `applyHotkeys` closure but not yet *exercised* by any UI (no hotkey-editing control exists before Task 7). Task 7 does not re-touch this function; it only adds the caller.

- [ ] **Step 1: Create `PreferencesModel.swift`**

Create `Sources/SXApp/PreferencesModel.swift`:

```swift
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
```

- [ ] **Step 2: Create `PreferencesView.swift` with 5 stub tabs**

Create `Sources/SXApp/PreferencesView.swift`:

```swift
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(PreferencesTab.general)
            CaptureTab(model: model)
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
                .tag(PreferencesTab.capture)
            HotkeysTab(model: model)
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
                .tag(PreferencesTab.hotkeys)
            UploadsTab(model: model)
                .tabItem { Label("Uploads", systemImage: "arrow.up.circle") }
                .tag(PreferencesTab.uploads)
            RecordingTab(model: model)
                .tabItem { Label("Recording", systemImage: "video") }
                .tag(PreferencesTab.recording)
        }
        .frame(width: 560, height: 420)
    }
}

private struct GeneralTab: View {
    @ObservedObject var model: PreferencesModel
    var body: some View {
        Text("General").padding()
    }
}

private struct CaptureTab: View {
    @ObservedObject var model: PreferencesModel
    var body: some View {
        Text("Capture").padding()
    }
}

private struct HotkeysTab: View {
    @ObservedObject var model: PreferencesModel
    var body: some View {
        Text("Hotkeys").padding()
    }
}

private struct UploadsTab: View {
    @ObservedObject var model: PreferencesModel
    var body: some View {
        Text("Uploads").padding()
    }
}

private struct RecordingTab: View {
    @ObservedObject var model: PreferencesModel
    var body: some View {
        Text("Recording").padding()
    }
}
```

- [ ] **Step 3: Create `PreferencesWindowController.swift`**

Create `Sources/SXApp/PreferencesWindowController.swift`:

```swift
import AppKit
import SwiftUI
import SXCore

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
```

- [ ] **Step 4: Wire `AppDelegate`: field, construction, menu item, `showPreferences`, `reapplyHotkeys`**

In `Sources/SXApp/AppDelegate.swift`, change the stored-properties block:

```swift
    private var destinationsWindow: DestinationsWindowController?
    private var historyStore: HistoryStore?
    private var historyWindow: HistoryWindowController?
```

to:

```swift
    private var destinationsWindow: DestinationsWindowController?
    private var preferencesWindow: PreferencesWindowController?
    private var historyStore: HistoryStore?
    private var historyWindow: HistoryWindowController?
```

Change the `destinationsWindow` construction in `applicationDidFinishLaunching`:

```swift
        destinationsWindow = DestinationsWindowController(
            store: store, credentials: KeychainCredentialStore(),
            onChange: { [weak self] in self?.rebuildMenu() })
        statusItem = StatusItemController(menu: buildMenu())
```

to:

```swift
        destinationsWindow = DestinationsWindowController(
            store: store, credentials: KeychainCredentialStore(),
            onChange: { [weak self] in self?.rebuildMenu() })
        preferencesWindow = PreferencesWindowController(
            store: store, credentials: KeychainCredentialStore(),
            onChange: { [weak self] in self?.rebuildMenu() },
            applyHotkeys: { [weak self] hotkeys in self?.reapplyHotkeys(hotkeys) })
        statusItem = StatusItemController(menu: buildMenu())
```

Change `buildMenu()`'s tail (History… → separator → Quit):

```swift
        menu.addItem(menuItem("History…", #selector(showHistory)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Lumeshot",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
```

to:

```swift
        menu.addItem(menuItem("History…", #selector(showHistory)))
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showPreferences),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "Quit Lumeshot",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
```

Add `showPreferences()` alongside the other window-opening `@objc` handlers (near `manageDestinations`/`showHistory`):

```swift
    @objc private func showPreferences() { preferencesWindow?.show() }
```

Add `reapplyHotkeys(_:)` immediately after `registerHotkeys(_:)`:

```swift
    /// Re-registers all global hotkeys after a Preferences edit. HotkeyManager
    /// has no per-hotkey unregister, and its Carbon registrations persist at
    /// the OS level independent of Swift object lifetime — skipping
    /// unregisterAll() here would leak the old registrations. Mirrors the
    /// app's own launch sequence (see exploration §3).
    private func reapplyHotkeys(_ config: HotkeySettings) {
        hotkeys?.unregisterAll()
        hotkeys = nil
        registerHotkeys(config)
    }
```

- [ ] **Step 5: Run the build**

Run: `scripts/remote.sh build`
Expected: `Build complete!`

- [ ] **Step 6: Run the full test suite (no new tests — confirm no regression)**

Run: `scripts/remote.sh test`
Expected: PASS — every pre-existing suite unchanged (`SXApp` has no test target; this task only touches `SXApp` files).

Manual smoke (deferred to Task 8's `docs/smoke-prefs.md`): `scripts/remote.sh run`, then from the status-bar menu confirm **Settings…** (and its ⌘, keyEquivalent) opens a window titled "Lumeshot Settings" with 5 tabs (General/Capture/Hotkeys/Uploads/Recording), each showing its stub label; closing and reopening reuses the same window instead of creating a second one.

- [ ] **Step 7: Commit**

```bash
git add Sources/SXApp/PreferencesWindowController.swift Sources/SXApp/PreferencesModel.swift Sources/SXApp/PreferencesView.swift Sources/SXApp/AppDelegate.swift
git commit -m "Add a tabbed Preferences window shell + Settings menu item"
```

---
### Task 2: `PreferencesModel` core (`update`) + General tab

**Files:**
- Modify: `Sources/SXApp/PreferencesModel.swift`
- Modify: `Sources/SXApp/PreferencesView.swift`
- Test: none. Build-only + Mac smoke.

**Interfaces:**
- Produces: `PreferencesModel.update(_ mutate: (inout AppSettings) -> Void)` — the load-mutate-save-notify shape, mirroring `DestinationsModel.persist` (`Sources/SXApp/DestinationsView.swift:20-33`) so it never clobbers the Uploads tab's independently-persisted slice.
- Consumes: `AppLog.log(_:)` (`Sources/SXApp/AppLog.swift`, same module, no import needed).
- General tab binds 4 `Toggle`s (`saveToDisk`, `copyToClipboard`, `showNotification`, `editor.annotateBeforeShare`) through inline `Binding(get:set:)`, per the contract's literal wording ("SwiftUI controls bind through custom `Binding(get:set:)` that reads `settings.<field>` and calls `update { $0.<field> = newValue }`") — no generic keyPath helper is introduced.

- [ ] **Step 1: Add `update(_:)` to `PreferencesModel`**

In `Sources/SXApp/PreferencesModel.swift`, add inside the class body, after `init`:

```swift
    /// Load-mutate-save-notify: mirrors DestinationsModel.persist but for the
    /// non-upload slice of AppSettings, so General/Capture/Recording/Hotkeys
    /// edits here and Uploads-tab edits (routed through `destinations`) never
    /// clobber each other — each reloads the full file immediately before
    /// mutating and saving its own slice.
    func update(_ mutate: (inout AppSettings) -> Void) {
        var (s, _) = store.loadOrDefault()
        mutate(&s)
        do {
            try store.save(s)
            settings = s
            onChange()
        } catch {
            AppLog.log("Preferences: save failed: \(error)")
        }
    }
```

- [ ] **Step 2: Flesh out the General tab**

In `Sources/SXApp/PreferencesView.swift`, replace:

```swift
private struct GeneralTab: View {
    @ObservedObject var model: PreferencesModel
    var body: some View {
        Text("General").padding()
    }
}
```

with:

```swift
private struct GeneralTab: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        Form {
            Toggle("Save screenshots to disk", isOn: Binding(
                get: { model.settings.saveToDisk },
                set: { newValue in model.update { $0.saveToDisk = newValue } }
            ))
            Toggle("Copy to clipboard", isOn: Binding(
                get: { model.settings.copyToClipboard },
                set: { newValue in model.update { $0.copyToClipboard = newValue } }
            ))
            Toggle("Show notification", isOn: Binding(
                get: { model.settings.showNotification },
                set: { newValue in model.update { $0.showNotification = newValue } }
            ))
            Toggle("Annotate before sharing", isOn: Binding(
                get: { model.settings.editor.annotateBeforeShare },
                set: { newValue in model.update { $0.editor.annotateBeforeShare = newValue } }
            ))
        }
        .padding()
    }
}
```

- [ ] **Step 3: Run the build**

Run: `scripts/remote.sh build`
Expected: `Build complete!`

- [ ] **Step 4: Run the full test suite (no new tests — confirm no regression)**

Run: `scripts/remote.sh test`
Expected: PASS — every pre-existing suite unchanged. `SettingsStore`'s own round-trip/persistence behavior is already covered by `Tests/SXCoreTests/SettingsStoreTests.swift`; this task adds no new SXCore surface.

Manual smoke (deferred to Task 8): toggle each of the 4 General switches; confirm `~/Library/Application Support/ShareX-Mac/settings.json` reflects the change immediately (`cat` it over `scripts/remote.sh ssh`), and that the matching status-bar checkmark ("Upload After Capture" is unaffected; "Annotate Before Sharing" should flip) updates on the very next menu open.

- [ ] **Step 5: Commit**

```bash
git add Sources/SXApp/PreferencesModel.swift Sources/SXApp/PreferencesView.swift
git commit -m "Add PreferencesModel.update and wire the General tab"
```

---
### Task 3: Capture tab

**Files:**
- Modify: `Sources/SXApp/PreferencesView.swift`
- Test: none. Build-only + Mac smoke.

**Interfaces:**
- Consumes: `NSOpenPanel` (`AppKit`) — same `runModal() == .OK` idiom already used by `AppDelegate.importSxcu()` (`Sources/SXApp/AppDelegate.swift:279-291`). New `import AppKit` line added to `PreferencesView.swift`.
- Consumes: `(path as NSString).abbreviatingWithTildeInPath` for display; the stored value is the raw `NSOpenPanel`-returned absolute path (not re-collapsed to `~` before saving) — the contract's own wording only asks for `~`-collapsing "for display." Every consumer of `captureSavePath` already calls `.expandingTildeInPath` on it (exploration §2), which is a no-op on an already-absolute path, so this is not a behavior change.
- Produces: no new model methods — both controls route through `PreferencesModel.update(_:)` from Task 2.

- [ ] **Step 1: Add `import AppKit` and flesh out the Capture tab**

In `Sources/SXApp/PreferencesView.swift`, change the import block:

```swift
import SwiftUI
```

to:

```swift
import AppKit
import SwiftUI
```

Replace:

```swift
private struct CaptureTab: View {
    @ObservedObject var model: PreferencesModel
    var body: some View {
        Text("Capture").padding()
    }
}
```

with:

```swift
private struct CaptureTab: View {
    @ObservedObject var model: PreferencesModel

    private var displayPath: String {
        (model.settings.captureSavePath as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        Form {
            HStack {
                TextField("Save Folder", text: .constant(displayPath))
                    .disabled(true)
                Button("Choose…") { chooseFolder() }
            }
            TextField("Filename Template", text: Binding(
                get: { model.settings.filenameTemplate },
                set: { newValue in model.update { $0.filenameTemplate = newValue } }
            ))
            Text("Tokens: %y year  %mo month  %d day  %h hour  %mi minute  %s second")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.update { $0.captureSavePath = url.path }
    }
}
```

- [ ] **Step 2: Run the build**

Run: `scripts/remote.sh build`
Expected: `Build complete!`

- [ ] **Step 3: Run the full test suite (no new tests — confirm no regression)**

Run: `scripts/remote.sh test`
Expected: PASS — every pre-existing suite unchanged.

Manual smoke (deferred to Task 8): open Capture tab, confirm the Save Folder field shows `~/Pictures/ShareX` (the default, abbreviated); click **Choose…**, pick a different folder; confirm the field updates and a capture (⌥⇧3) lands in the new folder. Edit the filename template; confirm the next capture's filename reflects it.

- [ ] **Step 4: Commit**

```bash
git add Sources/SXApp/PreferencesView.swift
git commit -m "Wire the Capture tab (save folder picker + filename template)"
```

---
### Task 4: Recording tab

**Files:**
- Modify: `Sources/SXApp/PreferencesView.swift`
- Test: none. Build-only + Mac smoke.

**Interfaces:**
- Consumes: `RecordingSettings.VideoCodec` (`Sources/SXCore/RecordingSettings.swift:13`, `enum VideoCodec: String, Codable, Equatable, Sendable { case h264, hevc }`). New `import SXCore` line added to `PreferencesView.swift` for this type name.
- **Ambiguity resolution #3 (ground truth wins):** `VideoCodec` conforms to `Equatable`/`Codable`/`Sendable` but **not** `Hashable`, and SwiftUI's `Picker`/`.tag(_:)` selection requires `Value: Hashable`. Adding `Hashable` to `RecordingSettings.swift` is out of this task's file list (and the contract gives no reason to touch `SXCore` here). This plan instead binds the `Picker`'s `selection` to the codec's `String` `rawValue` (`String` is trivially `Hashable`) and converts back via `RecordingSettings.VideoCodec(rawValue:)` on write — functionally identical, zero `SXCore` changes.
- `gifFPS` binds through a `Stepper(value:in:)` clamped to `1...60` (contract: "sane clamp e.g. 1…60"). `gifMaxWidth` reuses the exact `Int(text).flatMap { $0 > 0 ? $0 : nil }` "empty/zero/negative → nil (source width)" parsing idiom already established in `GifExportSheet` (`Sources/SXApp/HistoryView.swift`, M5b P2) rather than inventing a new convention.

- [ ] **Step 1: Add `import SXCore` and flesh out the Recording tab**

In `Sources/SXApp/PreferencesView.swift`, change the import block:

```swift
import AppKit
import SwiftUI
```

to:

```swift
import AppKit
import SwiftUI
import SXCore
```

Replace:

```swift
private struct RecordingTab: View {
    @ObservedObject var model: PreferencesModel
    var body: some View {
        Text("Recording").padding()
    }
}
```

with:

```swift
private struct RecordingTab: View {
    @ObservedObject var model: PreferencesModel
    @State private var gifMaxWidthText = ""

    var body: some View {
        Form {
            Toggle("Capture system audio", isOn: Binding(
                get: { model.settings.recording.systemAudio },
                set: { newValue in model.update { $0.recording.systemAudio = newValue } }
            ))
            // VideoCodec isn't Hashable, so Picker binds through its String
            // rawValue rather than the enum itself (see Task 4's Interfaces).
            Picker("Video Codec", selection: Binding(
                get: { model.settings.recording.videoCodec.rawValue },
                set: { newValue in
                    guard let codec = RecordingSettings.VideoCodec(rawValue: newValue) else { return }
                    model.update { $0.recording.videoCodec = codec }
                }
            )) {
                Text("H.264").tag("h264")
                Text("HEVC").tag("hevc")
            }
            Stepper(value: Binding(
                get: { model.settings.recording.gifFPS },
                set: { newValue in model.update { $0.recording.gifFPS = newValue } }
            ), in: 1...60) {
                Text("GIF Frame Rate: \(model.settings.recording.gifFPS) fps")
            }
            TextField("GIF Max Width (blank = source width)", text: $gifMaxWidthText)
                .onAppear {
                    gifMaxWidthText = model.settings.recording.gifMaxWidth.map(String.init) ?? ""
                }
                .onChange(of: model.settings.recording.gifMaxWidth) { _, newValue in
                    gifMaxWidthText = newValue.map(String.init) ?? ""
                }
                .onSubmit {
                    // Non-numeric, zero, or negative input means "no max width" —
                    // same convention as HistoryView's GifExportSheet.
                    let width = Int(gifMaxWidthText).flatMap { $0 > 0 ? $0 : nil }
                    model.update { $0.recording.gifMaxWidth = width }
                }
        }
        .padding()
    }
}
```

- [ ] **Step 2: Run the build**

Run: `scripts/remote.sh build`
Expected: `Build complete!`

- [ ] **Step 3: Run the full test suite (no new tests — confirm no regression)**

Run: `scripts/remote.sh test`
Expected: PASS — every pre-existing suite unchanged.

Manual smoke (deferred to Task 8): toggle System Audio and confirm the status-bar "System Audio" checkmark matches; switch codec to HEVC, record a clip, confirm the output is HEVC (`ffprobe`/QuickTime); set GIF FPS and max width, export a GIF from History, confirm the new values are honored.

- [ ] **Step 4: Commit**

```bash
git add Sources/SXApp/PreferencesView.swift
git commit -m "Wire the Recording tab (system audio, codec, GIF fps/width)"
```

---
### Task 5: Uploads tab (fold in Destinations)

**Files:**
- Modify: `Sources/SXApp/DestinationsView.swift`
- Modify: `Sources/SXApp/PreferencesView.swift`
- Modify: `Sources/SXApp/AppDelegate.swift`
- Test: none. Build-only + Mac smoke.

**Interfaces:**
- Produces: `DestinationsModel.setUploadAfterCapture(_ newValue: Bool)` — a thin wrapper around the existing private `persist(_:)`, so the toggle goes through the exact same load-mutate-save-refresh-notify path every other Destinations mutation uses.
- Consumes: `DestinationsView(model: DestinationsModel)` (`Sources/SXApp/DestinationsView.swift:152-153`) embedded as-is — it is "just a `VStack` with a `List` and sheets" (exploration §4), no window chrome of its own, trivially embeddable in a tab.
- **Ambiguity resolution #4:** the contract's default for retiring `DestinationsWindowController` is "repoint the menu item, leave the file." This plan repoints by editing the **body of the existing `manageDestinations()` handler** (one line) rather than removing the menu item, renaming it, or deleting/pruning `destinationsWindow`'s field and construction in `AppDelegate` — the smallest possible diff that satisfies "leave the file" literally (the controller, its field, and its eager construction in `applicationDidFinishLaunching` are untouched; only what happens when the user chooses "Manage Destinations…" changes).

- [ ] **Step 1: Add `setUploadAfterCapture` to `DestinationsModel`**

In `Sources/SXApp/DestinationsView.swift`, add immediately after `reloadFromDisk()`:

```swift
    /// Persisted binding for the Uploads tab's "Upload after capture" toggle
    /// — goes through the same persist() as every other Destinations edit.
    func setUploadAfterCapture(_ newValue: Bool) {
        persist { $0.upload.uploadAfterCapture = newValue }
    }
```

- [ ] **Step 2: Flesh out the Uploads tab**

In `Sources/SXApp/PreferencesView.swift`, replace:

```swift
private struct UploadsTab: View {
    @ObservedObject var model: PreferencesModel
    var body: some View {
        Text("Uploads").padding()
    }
}
```

with:

```swift
private struct UploadsTab: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Upload after capture", isOn: Binding(
                get: { model.destinations.settings.uploadAfterCapture },
                set: { newValue in model.destinations.setUploadAfterCapture(newValue) }
            ))
            .padding([.horizontal, .top])
            Divider()
            DestinationsView(model: model.destinations)
        }
    }
}
```

- [ ] **Step 3: Repoint "Manage Destinations…" to open Preferences on the Uploads tab**

In `Sources/SXApp/AppDelegate.swift`, change:

```swift
    @objc private func manageDestinations() { destinationsWindow?.show() }
```

to:

```swift
    @objc private func manageDestinations() { preferencesWindow?.show(selecting: .uploads) }
```

- [ ] **Step 4: Run the build**

Run: `scripts/remote.sh build`
Expected: `Build complete!`

- [ ] **Step 5: Run the full test suite (no new tests — confirm no regression)**

Run: `scripts/remote.sh test`
Expected: PASS — every pre-existing suite unchanged, in particular every `S3Credentials`/`SFTPCredentials`/`FTPCredentials`/`SecretVault` Keychain test in `SXCoreTests`, since `DestinationsModel`'s add/remove/purge methods are completely untouched by this task (only a new sibling method was added).

Manual smoke (deferred to Task 8): status-bar → **Manage Destinations…** now opens "Lumeshot Settings" pre-selected on the Uploads tab; toggle "Upload after capture" and confirm the status-bar checkmark of the same name follows it; add an S3/Imgur/SFTP/FTP destination and remove one, confirming Keychain entries are written/purged exactly as before (no change to that code path).

- [ ] **Step 6: Commit**

```bash
git add Sources/SXApp/DestinationsView.swift Sources/SXApp/PreferencesView.swift Sources/SXApp/AppDelegate.swift
git commit -m "Fold Destinations management into the Preferences Uploads tab"
```

---
### Task 6: Hotkey display/formatting in SXCore (CI-TESTED)

**Files:**
- Create: `Sources/SXCore/HotkeyFormatting.swift`
- Test: Create `Tests/SXCoreTests/HotkeyFormattingTests.swift`

**Interfaces:**
- Produces: `HotkeyCombo.displayString: String` — renders `modifiers` (Carbon mask) in canonical `⌃⌥⇧⌘` order followed by `keyCode`'s human label (letters/digits/punctuation/arrows/space/a handful of common editing keys); an unmapped `keyCode` falls back to `"Key<N>"`.
- Produces: `enum HotkeyModifiers` — pure (no `AppKit`/`Carbon` import, so `SXCore` stays platform-formatting-only) namespace of the 4 relevant mask bit values on both sides plus two converters: `static func carbonMask(fromAppKit raw: UInt) -> UInt32` and `static func appKitRaw(fromCarbon mask: UInt32) -> UInt`. `raw`/the return of `appKitRaw` are the exact bit layout of `NSEvent.ModifierFlags.rawValue` (`UInt`); the caller in `SXApp` (Task 7) is responsible for `event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue` before calling in, so `HotkeyModifiers` never needs to know about caps-lock/function/numeric-pad bits.
- Consumed by: Task 7's `HotkeyRecorderField` (`carbonMask(fromAppKit:)`, to build a `HotkeyCombo` from a captured `NSEvent`) and the Hotkeys tab (`displayString`, to render the current/idle combo).
- Values verified live against `AppSettings.default` (`Sources/SXCore/AppSettings.swift:103-119`): `fullscreen = HotkeyCombo(keyCode: 20, modifiers: 2560)`, `region = HotkeyCombo(keyCode: 21, modifiers: 2560)`, `window = HotkeyCombo(keyCode: 23, modifiers: 2560)`, `record = HotkeyCombo(keyCode: 22, modifiers: 2560)`. `2560 = optionKey(2048) | shiftKey(512)` (comment already in source). Carbon virtual keycodes 20/21/23/22 map to the physical digits "3"/"4"/"5"/"6" respectively (macOS ANSI virtual-keycode layout — keycodes are positional, not sequential: keyCode 22 is physically "6", 23 is physically "5").

- [ ] **Step 1: Create `HotkeyFormatting.swift`**

Create `Sources/SXCore/HotkeyFormatting.swift`:

```swift
import Foundation

/// Pure (no AppKit/Carbon import) conversion between the Carbon modifier mask
/// stored in HotkeyCombo.modifiers and the raw bit layout of AppKit's
/// NSEvent.ModifierFlags, so this file has no platform-framework dependency
/// and Tests/SXCoreTests can exercise it without a live NSEvent.
///
/// Carbon masks (Events.h): cmdKey=256, shiftKey=512, optionKey=2048, controlKey=4096.
/// AppKit raw bits (NSEvent.h): shift=1<<17, control=1<<18, option=1<<19, command=1<<20.
public enum HotkeyModifiers {
    public static let carbonCommand: UInt32 = 256
    public static let carbonShift: UInt32 = 512
    public static let carbonOption: UInt32 = 2048
    public static let carbonControl: UInt32 = 4096

    public static let appKitShift: UInt = 1 << 17
    public static let appKitControl: UInt = 1 << 18
    public static let appKitOption: UInt = 1 << 19
    public static let appKitCommand: UInt = 1 << 20

    /// `raw` is expected to already be masked to NSEvent's device-independent
    /// modifier bits (the caller intersects with `.deviceIndependentFlagsMask`
    /// before passing it in) — this function only inspects the 4 bits above.
    public static func carbonMask(fromAppKit raw: UInt) -> UInt32 {
        var mask: UInt32 = 0
        if raw & appKitControl != 0 { mask |= carbonControl }
        if raw & appKitOption  != 0 { mask |= carbonOption }
        if raw & appKitShift   != 0 { mask |= carbonShift }
        if raw & appKitCommand != 0 { mask |= carbonCommand }
        return mask
    }

    public static func appKitRaw(fromCarbon mask: UInt32) -> UInt {
        var raw: UInt = 0
        if mask & carbonControl != 0 { raw |= appKitControl }
        if mask & carbonOption  != 0 { raw |= appKitOption }
        if mask & carbonShift   != 0 { raw |= appKitShift }
        if mask & carbonCommand != 0 { raw |= appKitCommand }
        return raw
    }
}

public extension HotkeyCombo {
    /// Carbon virtual-keycode -> human label for the keys a global hotkey can
    /// reasonably use: letters, digits, common punctuation, arrows, space,
    /// and a handful of editing/navigation keys. Unlisted keycodes fall back
    /// to "Key<N>" rather than silently rendering nothing.
    private static let keyLabels: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 36: "\u{21A9}",   // Return
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "\u{21E5}",   // Tab
        49: "Space", 50: "`", 51: "\u{232B}",         // Delete (backspace)
        53: "\u{238B}",                                // Escape
        115: "Home", 116: "Page Up", 117: "\u{2326}",  // Forward Delete
        119: "End", 121: "Page Down",
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
    ]

    /// Canonical macOS modifier glyph order: Control, Option, Shift, Command.
    var displayString: String {
        var s = ""
        if modifiers & HotkeyModifiers.carbonControl != 0 { s += "\u{2303}" }
        if modifiers & HotkeyModifiers.carbonOption  != 0 { s += "\u{2325}" }
        if modifiers & HotkeyModifiers.carbonShift   != 0 { s += "\u{21E7}" }
        if modifiers & HotkeyModifiers.carbonCommand != 0 { s += "\u{2318}" }
        s += Self.keyLabels[keyCode] ?? "Key\(keyCode)"
        return s
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/SXCoreTests/HotkeyFormattingTests.swift`:

```swift
import Testing
import Foundation
@testable import SXCore

@Suite struct HotkeyFormattingTests {
    // Default combos, verified live against AppSettings.default.
    @Test func fullscreenComboRendersAsOptionShift3() {
        #expect(HotkeyCombo(keyCode: 20, modifiers: 2560).displayString == "\u{2325}\u{21E7}3")
    }

    @Test func regionComboRendersAsOptionShift4() {
        #expect(HotkeyCombo(keyCode: 21, modifiers: 2560).displayString == "\u{2325}\u{21E7}4")
    }

    @Test func windowComboRendersAsOptionShift5() {
        #expect(HotkeyCombo(keyCode: 23, modifiers: 2560).displayString == "\u{2325}\u{21E7}5")
    }

    @Test func recordComboRendersAsOptionShift6() {
        #expect(HotkeyCombo(keyCode: 22, modifiers: 2560).displayString == "\u{2325}\u{21E7}6")
    }

    @Test func defaultAppSettingsHotkeysMatchTheirExpectedDisplayStrings() {
        let hotkeys = AppSettings.default.hotkeys
        #expect(hotkeys.fullscreen?.displayString == "\u{2325}\u{21E7}3")
        #expect(hotkeys.region?.displayString == "\u{2325}\u{21E7}4")
        #expect(hotkeys.window?.displayString == "\u{2325}\u{21E7}5")
        #expect(hotkeys.record?.displayString == "\u{2325}\u{21E7}6")
    }

    @Test func allFourModifiersRenderInCanonicalControlOptionShiftCommandOrder() {
        let mask = HotkeyModifiers.carbonControl | HotkeyModifiers.carbonOption
            | HotkeyModifiers.carbonShift | HotkeyModifiers.carbonCommand
        #expect(HotkeyCombo(keyCode: 49, modifiers: mask).displayString
                == "\u{2303}\u{2325}\u{21E7}\u{2318}Space")
    }

    @Test func modifierMaskRoundTripsFromAppKitToCarbonAndBack() {
        let appKitRaw = HotkeyModifiers.appKitControl | HotkeyModifiers.appKitShift
        let carbon = HotkeyModifiers.carbonMask(fromAppKit: appKitRaw)
        #expect(carbon == HotkeyModifiers.carbonControl | HotkeyModifiers.carbonShift)
        #expect(HotkeyModifiers.appKitRaw(fromCarbon: carbon) == appKitRaw)
    }

    @Test func modifierMaskRoundTripsAllFourBitsIndependently() {
        for carbonBit in [HotkeyModifiers.carbonControl, HotkeyModifiers.carbonOption,
                          HotkeyModifiers.carbonShift, HotkeyModifiers.carbonCommand] {
            let appKit = HotkeyModifiers.appKitRaw(fromCarbon: carbonBit)
            #expect(HotkeyModifiers.carbonMask(fromAppKit: appKit) == carbonBit)
        }
    }

    @Test func unknownKeyCodeFallsBackToKeyPlusCode() {
        #expect(HotkeyCombo(keyCode: 9999, modifiers: 0).displayString == "Key9999")
    }

    @Test func noModifiersRendersJustTheKeyLabel() {
        #expect(HotkeyCombo(keyCode: 0, modifiers: 0).displayString == "A")
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: FAIL — `Sources/SXCore/HotkeyFormatting.swift` doesn't exist yet, so `Tests/SXCoreTests/HotkeyFormattingTests.swift` fails to compile (`HotkeyModifiers`/`.displayString` undefined).

- [ ] **Step 4: Confirm Step 1's file is present, then re-run**

(Step 1 already created `Sources/SXCore/HotkeyFormatting.swift` — this step is the actual "make it pass" run.)

Run: `scripts/remote.sh test`
Expected: PASS — all 10 new `HotkeyFormattingTests` cases, plus every pre-existing `SXCoreTests` case (in particular `HotkeySettingsTests`/`RecordingSettingsTests`, unaffected — this task adds a new file, it doesn't touch `AppSettings.swift`/`RecordingSettings.swift`).

- [ ] **Step 5: Commit**

```bash
git add Sources/SXCore/HotkeyFormatting.swift Tests/SXCoreTests/HotkeyFormattingTests.swift
git commit -m "Add HotkeyCombo.displayString and HotkeyModifiers Carbon/AppKit mapping"
```

---
### Task 7: Hotkeys tab — live recorder control + wiring + re-register

**Files:**
- Create: `Sources/SXApp/HotkeyRecorderField.swift`
- Modify: `Sources/SXApp/PreferencesModel.swift`
- Modify: `Sources/SXApp/PreferencesView.swift`
- Test: none (SXApp has no test target; the mapping it calls into is already CI-covered by Task 6). Build-only + Mac smoke — a live keypress + global re-registration can only be verified on the Mac.

**Interfaces:**
- Produces: `PreferencesModel.updateHotkeys(_ mutate: (inout HotkeySettings) -> Void)` — persists via `update(_:)` (Task 2) then calls the `applyHotkeys` closure (wired in Task 1, pointing at `AppDelegate.reapplyHotkeys(_:)`, implemented in Task 1) with the freshly-saved `settings.hotkeys`.
- Produces: `struct HotkeyRecorderField: View { let combo: HotkeyCombo?; let onChange: (HotkeyCombo?) -> Void }` — idle state shows `combo?.displayString ?? "Click to record"`; clicking starts recording (button label becomes "Press a key…") and installs `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`; the next keyDown is converted to a `HotkeyCombo` via `HotkeyModifiers.carbonMask(fromAppKit:)` (Task 6) and reported through `onChange`; a trailing "clear" button (shown only when `combo != nil`) calls `onChange(nil)`.
- Consumes: `HotkeyCombo`, `HotkeyModifiers` (Task 6, `SXCore`).
- **Ambiguity resolution #5:** the contract says "Guard against registering an empty/modifier-only combo." A standalone modifier press (e.g. just ⌥) never generates an AppKit `.keyDown` event on its own (only `.flagsChanged`), so listening exclusively to `.keyDown` already excludes "modifier-only." The one guard this task adds explicitly is **zero modifiers**: recording a bare, unmodified key (e.g. plain `A`) as a system-wide global hotkey would shadow ordinary typing everywhere, so the monitor's handler requires `carbonMods != 0` before accepting a capture — an unmodified keypress while recording is silently ignored (the field stays in "Press a key…" state) rather than producing a combo.

- [ ] **Step 1: Create `HotkeyRecorderField.swift`**

Create `Sources/SXApp/HotkeyRecorderField.swift`:

```swift
import AppKit
import SwiftUI
import SXCore

/// A "click to record" control for a single global hotkey. Mirrors the
/// System Settings > Keyboard Shortcuts recording UX: idle shows the current
/// combo (or a prompt); clicking installs a local keyDown monitor that
/// captures the very next modified keypress and reports it back, then tears
/// the monitor down. A trailing clear button (visible only when a combo is
/// set) reports nil.
struct HotkeyRecorderField: View {
    let combo: HotkeyCombo?
    let onChange: (HotkeyCombo?) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                Text(isRecording ? "Press a key…" : (combo?.displayString ?? "Click to record"))
                    .frame(minWidth: 90)
            }
            .buttonStyle(.bordered)
            if combo != nil {
                Button {
                    stopRecording()
                    onChange(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Clear this hotkey")
            }
        }
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let carbonMods = HotkeyModifiers.carbonMask(
                fromAppKit: event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
            // A hotkey with no modifier at all would shadow ordinary typing
            // system-wide the instant it's registered — ignore it and keep
            // recording instead of producing an unmodified global hotkey.
            guard carbonMods != 0 else { return event }
            let newCombo = HotkeyCombo(keyCode: UInt32(event.keyCode), modifiers: carbonMods)
            stopRecording()
            onChange(newCombo)
            return nil   // swallow the keypress that finished recording
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
```

- [ ] **Step 2: Add `updateHotkeys(_:)` to `PreferencesModel`**

In `Sources/SXApp/PreferencesModel.swift`, add immediately after `update(_:)`:

```swift
    /// Persists a hotkeys-only edit, then re-registers the global hotkeys
    /// immediately so the change takes effect without an app relaunch —
    /// hotkeys are the one setting AppDelegate caches at launch instead of
    /// re-reading fresh per use (exploration §3).
    func updateHotkeys(_ mutate: (inout HotkeySettings) -> Void) {
        update { mutate(&$0.hotkeys) }
        applyHotkeys(settings.hotkeys)
    }
```

- [ ] **Step 3: Flesh out the Hotkeys tab**

In `Sources/SXApp/PreferencesView.swift`, replace:

```swift
private struct HotkeysTab: View {
    @ObservedObject var model: PreferencesModel
    var body: some View {
        Text("Hotkeys").padding()
    }
}
```

with:

```swift
private struct HotkeysTab: View {
    @ObservedObject var model: PreferencesModel

    var body: some View {
        Form {
            HotkeyRow(label: "Capture Fullscreen", combo: model.settings.hotkeys.fullscreen) { newCombo in
                model.updateHotkeys { $0.fullscreen = newCombo }
            }
            HotkeyRow(label: "Capture Region", combo: model.settings.hotkeys.region) { newCombo in
                model.updateHotkeys { $0.region = newCombo }
            }
            HotkeyRow(label: "Capture Window", combo: model.settings.hotkeys.window) { newCombo in
                model.updateHotkeys { $0.window = newCombo }
            }
            HotkeyRow(label: "Toggle Recording", combo: model.settings.hotkeys.record) { newCombo in
                model.updateHotkeys { $0.record = newCombo }
            }
        }
        .padding()
    }
}

private struct HotkeyRow: View {
    let label: String
    let combo: HotkeyCombo?
    let onChange: (HotkeyCombo?) -> Void

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            HotkeyRecorderField(combo: combo, onChange: onChange)
        }
    }
}
```

- [ ] **Step 4: Run the build**

Run: `scripts/remote.sh build`
Expected: `Build complete!`

- [ ] **Step 5: Run the full test suite (no new tests — confirm no regression)**

Run: `scripts/remote.sh test`
Expected: PASS — every pre-existing suite unchanged, including Task 6's `HotkeyFormattingTests` (the mapping this task's UI calls into, already covered).

Manual smoke (deferred to Task 8, this is the trickiest live behavior in the whole plan — verify it thoroughly): open Hotkeys tab; click the Fullscreen recorder, press a new combo (e.g. ⌃⌥⇧2); confirm the field updates to show it immediately. Without relaunching the app, press the **new** combo and confirm it triggers a fullscreen capture; press the **old** combo (⌥⇧3) and confirm it does **nothing** (proves `unregisterAll()` actually ran, not just an additive re-register). Click "clear" on a hotkey and confirm that combo no longer fires. Repeat for Region/Window/Record.

- [ ] **Step 6: Commit**

```bash
git add Sources/SXApp/HotkeyRecorderField.swift Sources/SXApp/PreferencesModel.swift Sources/SXApp/PreferencesView.swift
git commit -m "Add the live hotkey recorder and wire the Hotkeys tab"
```

---
### Task 8: Docs + final pass

**Files:**
- Create: `docs/smoke-prefs.md`
- Test: none (docs). This task also runs the final full build+test pass as its own verification.

**Interfaces:** Consumes everything built in Tasks 1–7. No code changes.

- [ ] **Step 1: Write `docs/smoke-prefs.md`**

Create `docs/smoke-prefs.md`:

```markdown
# Preferences window manual smoke checklist

Run on the Mac after `scripts/remote.sh run`. Diagnostics: `~/Library/Logs/ShareX-Mac.log`.
Covers the tabbed Preferences window (Tasks 1–5, 7) end to end; Task 6's hotkey
formatting/mapping is covered by `Tests/SXCoreTests/HotkeyFormattingTests.swift`, not
re-verified here.

- [ ] **Window opens and reuses (Task 1):** Status-bar menu → **Settings…** (confirm the ⌘,
      keyEquivalent also opens it while the status-bar menu is open). A window titled
      "Lumeshot Settings" appears with 5 tabs: General, Capture, Hotkeys, Uploads, Recording.
      Close it and reopen via the menu; confirm it's the same window (position/selected tab
      persist within the app session), not a second window stacking on top.
- [ ] **General tab persists + live-applies (Task 2):** Toggle each of the 4 switches (Save
      to Disk, Copy to Clipboard, Show Notification, Annotate Before Sharing). Confirm
      `settings.json` reflects each change immediately and the "Annotate Before Sharing"
      status-bar checkmark follows the last one.
- [ ] **Capture tab (Task 3):** Confirm the Save Folder field shows `~/Pictures/ShareX`
      abbreviated with `~`. Click **Choose…**, pick a new folder; capture (⌥⇧3) and confirm
      the file lands there. Edit the filename template; confirm the next capture's name
      matches it.
- [ ] **Recording tab (Task 4):** Toggle System Audio; confirm the status-bar checkmark
      matches. Switch codec to HEVC, record a clip, confirm it plays back as HEVC. Set GIF fps
      and max width, export a GIF from History, confirm both are honored.
- [ ] **Uploads tab folds in Destinations (Task 5):** Status-bar → **Manage Destinations…**
      now opens Preferences pre-selected on Uploads. Toggle "Upload after capture"; confirm
      the same-named status-bar checkmark follows it. Add an S3 (or Imgur/SFTP/FTP)
      destination and then remove it; confirm no regression in the Keychain-first
      store/purge flow (same behavior as before this feature — see `docs/smoke-m5a.md` for
      the detailed SFTP/FTP Keychain checklist).
- [ ] **Hotkeys tab: live recorder + re-register (Task 7):** Click the Fullscreen recorder,
      press a new combo (e.g. ⌃⌥⇧2); the field updates immediately. Without relaunching,
      confirm the NEW combo triggers a fullscreen capture and the OLD combo (⌥⇧3) no longer
      does anything (proves the old Carbon registration was actually unregistered, not just
      shadowed). Click "clear" on a hotkey and confirm it stops firing. Repeat for
      Region/Window/Record.

M1 capture smoke: see `docs/smoke-m1.md`. M2a upload smoke: see `docs/smoke-m2a.md`.
M4 recording smoke: see `docs/smoke-m4.md`. M5a SFTP/FTP smoke: see `docs/smoke-m5a.md`.
M5b release/polish smoke: see `docs/smoke-m5b.md`.
```

- [ ] **Step 2: Run the full build + test suite one last time**

Run: `scripts/remote.sh build`
Expected: `Build complete!`

Run: `scripts/remote.sh test`
Expected: PASS — `Tests/SXCoreTests/HotkeyFormattingTests.swift` (Task 6) plus every pre-existing suite across `SXCoreTests`/`SXCaptureTests`/`SXUploadTests`/`SXAnnotateTests`/`SXRecordTests`, unchanged.

- [ ] **Step 3: Commit**

```bash
git add docs/smoke-prefs.md
git commit -m "Add the Preferences window manual smoke checklist"
```

- [ ] **Step 4: Run the Mac Smoke Checklist**

Deploy with `scripts/remote.sh run`, then work through `docs/smoke-prefs.md` (reproduced in Step 1 above) before considering this feature done.

---
## Self-Review

*(Author checklist against the ratified architecture contract, `/tmp/prefs-contract.md`.)*

**1. Contract coverage** — each contract task → the plan task that satisfies it:
- Task 1 (`PreferencesWindowController` + tabbed shell + minimal model + menu item + `reapplyHotkeys` wiring) → Plan Task 1, exact init signatures from the contract's Architecture section, window-controller pattern copied verbatim from `HistoryWindowController`/`DestinationsWindowController` (read live before writing). ✅
- Task 2 (`update{}` + Binding helper + General tab, 4 toggles) → Plan Task 2, `update(_:)` mirrors `DestinationsModel.persist` exactly; General tab uses the contract's literal inline-`Binding(get:set:)` idiom, not a generic keyPath abstraction. ✅
- Task 3 (Capture tab: folder row + Choose… + filename template + token legend) → Plan Task 3, `NSOpenPanel` idiom copied from `AppDelegate.importSxcu()`. ✅
- Task 4 (Recording tab: systemAudio/videoCodec/gifFPS/gifMaxWidth) → Plan Task 4, with the `VideoCodec`-isn't-`Hashable` gap resolved via a `String`-rawValue `Picker` binding instead of a `SXCore` change (Ambiguity resolution #3). ✅
- Task 5 (Uploads tab folds in Destinations; `uploadAfterCapture` binding; repoint menu item) → Plan Task 5, `DestinationsModel.setUploadAfterCapture` added, `DestinationsView` embedded unmodified, Keychain flow untouched. ✅
- Task 6 (SXCore hotkey formatting, CI-tested) → Plan Task 6, `HotkeyCombo.displayString` + `HotkeyModifiers` mapping, values verified live against `AppSettings.default`, 10 `@Test` cases in `Tests/SXCoreTests/HotkeyFormattingTests.swift`. ✅
- Task 7 (live recorder + wiring + re-register) → Plan Task 7, `HotkeyRecorderField` local-monitor recorder exactly as the contract describes it, `updateHotkeys(_:)` → `applyHotkeys` → `AppDelegate.reapplyHotkeys(_:)` (the exact `unregisterAll()` → `hotkeys = nil` → `registerHotkeys()` sequence, implemented in Task 1 and exercised here for the first time). ✅
- Task 8 (docs + final pass) → Plan Task 8, `docs/smoke-prefs.md` + final `scripts/remote.sh build`+`test`. ✅
- Task ordering (1→2→3→4→5→6→7→8) → followed exactly. ✅

**2. Placeholder scan** — grep for `TBD`/`TODO`/`similar to Task`/`add the rest similarly`/trailing `…` as a stand-in for real code: clean. Every code block is a complete, real implementation written against the live signatures captured in the exploration report and re-verified by reading the actual source files (`AppSettings.swift`, `AppDelegate.swift`, `HotkeyManager.swift`, `DestinationsView.swift`, `DestinationsWindowController.swift`, `HistoryWindowController.swift`, `SettingsStore.swift`, `RecordingSettings.swift`) before this plan was written. No task ships a stub tab body that survives past the task that's supposed to flesh it out, and no task leaves a "wire this up later" comment where code was asked for.

**3. CI-tested vs. build-only/smoke-only, matching the Global Constraints exactly:**
- CI-tested: **Task 6 only** (`Tests/SXCoreTests/HotkeyFormattingTests.swift`) — 10 `@Test` cases covering all 4 default combos' exact display strings, canonical 4-modifier ordering, bidirectional modifier-mask round-tripping, and an unmapped-keycode fallback.
- Build-only + Mac smoke, no unit test (no `SXAppTests` target exists): **Tasks 1, 2, 3, 4, 5, 7** — every step in these tasks runs `scripts/remote.sh build` then `scripts/remote.sh test` (confirming zero regression to the existing suites) and defers manual verification to `docs/smoke-prefs.md`, authored in Task 8. No task invents a `Tests/SXAppTests/` file or a fake UI unit test to work around the missing test target.
- Docs + final full-suite pass: **Task 8** — no code, `docs/smoke-prefs.md` plus one last `scripts/remote.sh build`+`test`.

**4. Secrets/Keychain invariant** — confirmed not regressed: Task 5 adds exactly one new method to `DestinationsModel` (`setUploadAfterCapture`, a thin wrapper around the existing private `persist(_:)`) and otherwise embeds `DestinationsView`/`DestinationsModel` completely unchanged. Every `addS3`/`addSFTP`/`addFTP`/`addImgur`/`remove` call path — including the Keychain-store-then-persist-then-rollback-on-save-failure sequence — is untouched by this plan.

**5. Ambiguities resolved in favor of live source (surfaced in each task's Interfaces, recapped here):**
- **#1 (Task 1):** `preferencesWindow` is constructed eagerly in `applicationDidFinishLaunching` (mirroring `destinationsWindow`), not lazily on first use (which is what `historyWindow` does) — the contract's "lazy, mirrors destinationsWindow/historyWindow" wording conflates two different existing patterns; this plan picks the eager one since all dependencies are already in scope at that call site.
- **#2 (Task 1):** `AppDelegate.reapplyHotkeys(_:)` is implemented in full in Task 1 (its 3-line body has zero unknowns per exploration §3), not left as an inert stub until Task 7 — Task 7 only adds its first caller.
- **#3 (Task 4):** `RecordingSettings.VideoCodec` is not `Hashable`, so the Recording tab's codec `Picker` binds through the enum's `String` `rawValue` instead of the enum directly, avoiding an out-of-scope `SXCore` change.
- **#4 (Task 5):** "Manage Destinations…" is repointed by editing the one-line body of the existing `manageDestinations()` `@objc` handler, not by touching the menu item's construction or removing `destinationsWindow`'s field/construction/file — satisfying the contract's own default ("repoint the menu item, leave the file") as literally as possible.
- **#5 (Task 7):** "Guard against registering an empty/modifier-only combo" is implemented as a single `carbonMods != 0` check in the keyDown handler; "modifier-only" is already excluded for free by listening only to `.keyDown` (a bare modifier press only ever generates `.flagsChanged`, which this recorder never observes).
