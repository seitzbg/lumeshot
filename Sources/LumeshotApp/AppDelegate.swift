import AppKit
import Combine
import LumeshotCore
import LumeshotRecord
import UniformTypeIdentifiers
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var uploadActivitySubscription: AnyCancellable?
    private var hotkeys: HotkeyManager?
    private var coordinator: CaptureCoordinator?
    private var preferencesWindow: PreferencesWindowController?
    private let aboutWindow = AboutWindowController()
    /// Sparkle's standard controller: it owns the scheduled checks, the download,
    /// EdDSA verification against SUPublicEDKey, installation and relaunch. Started
    /// eagerly so the scheduled check runs without the menu ever being opened.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var historyStore: HistoryStore?
    private var historyWindow: HistoryWindowController?
    private let editorWindow = EditorWindowController()
    private let effects = AppPipelineEffects()
    private var recordingCoordinator: RecordingCoordinator?
    private var elapsedMenuItem: NSMenuItem?
    private var elapsedTimer: Timer?
    private var recordingStartedAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !terminateIfDuplicateInstance() else { return }
        installMainMenu()
        let store = SettingsStore(fileURL: SettingsStore.defaultFileURL)
        let (settings, issue) = store.loadOrDefault()
        handleLoadIssue(issue)
        if !FileManager.default.fileExists(atPath: store.fileURL.path) {
            do {
                try store.save(settings)   // materialize defaults for hand-editing
            } catch {
                AppLog.log("Failed to materialize default settings at \(store.fileURL.path): \(error)")
            }
        }

        effects.setUpNotifications()
        let historyStore = try? HistoryStore(
            fileURL: SettingsStore.defaultFileURL.deletingLastPathComponent()
                .appendingPathComponent("history.sqlite"))
        if historyStore == nil { AppLog.log("History store unavailable; captures won't be recorded") }
        self.historyStore = historyStore
        let uploadService = UploadService(credentials: KeychainCredentialStore(),
                                          settingsStore: SettingsStore(fileURL: SettingsStore.defaultFileURL),
                                          activity: .shared)
        let coordinator = CaptureCoordinator(settingsStore: store, effects: effects,
                                             uploadService: uploadService,
                                             historyStore: historyStore,
                                             editorPresenter: editorWindow)
        self.coordinator = coordinator
        let recorder = ScreenRecorder()
        let recordingCoordinator = RecordingCoordinator(
            recorder: recorder, settingsStore: store, effects: effects,
            deliver: { [weak coordinator] url, appName in
                coordinator?.deliverRecording(fileURL: url, appName: appName)
            },
            onStateChange: { [weak self] on in self?.updateRecordingUI(on) })
        self.recordingCoordinator = recordingCoordinator
        preferencesWindow = PreferencesWindowController(
            store: store, credentials: KeychainCredentialStore(),
            onChange: { [weak self] in self?.rebuildMenu() },
            applyHotkeys: { [weak self] config in self?.reapplyHotkeys(config) },
            showAbout: { [weak self] in self?.aboutWindow.show() })
        statusItem = StatusItemController(menu: buildMenu())
        uploadActivitySubscription = Publishers.CombineLatest(UploadActivity.shared.$running, UploadActivity.shared.$latest)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.statusItem?.setUploadActivity(UploadActivity.shared)
                self?.rebuildMenu()
            }
        registerHotkeys(settings.hotkeys)
        AppLog.log("Launched (bundle: \(Bundle.main.bundleIdentifier ?? "none"), screenRecording=\(PermissionOnboardingController.isGranted()))")

        handleCLIArguments()
    }

    /// Settings temporarily gives the app a Dock icon and a visible main menu.
    /// The Edit menu also routes text shortcuts while running as an accessory.
    ///
    /// No Quit item on purpose: ⌘Q from a focused Preferences window would kill
    /// the whole app, and the status-bar menu already offers Quit deliberately.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Lumeshot")
        let about = appMenu.addItem(withTitle: "About Lumeshot", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        let updates = appMenu.addItem(withTitle: "Check for Updates…",
                                      action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showPreferences),
                                      keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Lumeshot", action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                        action: #selector(NSApplication.hideOtherApplications(_:)),
                                        keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        let history = file.addItem(withTitle: "History…", action: #selector(showHistory), keyEquivalent: "")
        history.target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        fileItem.submenu = file
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        // undo:/redo: are dynamic responder selectors, not declared on NSResponder.
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopening from Finder should also give a menu-bar app a visible window.
        // A Dock click recovers Settings even when it was minimized or hidden.
        guard preferencesWindow?.isOpen == true || !flag else { return true }
        preferencesWindow?.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.unregisterAll()
    }

    /// Enforces a single running instance. If another copy of this app (same
    /// bundle id) is already running, bring it forward and exit this one — so an
    /// accidental double-launch, or the dev loop's `open -n`, can't stack
    /// duplicate menu-bar icons and duplicate global hotkey registrations.
    /// First-wins (this new instance bows out) deliberately never terminates the
    /// existing instance, which may have an unsaved editor session open.
    /// Returns true if this instance is exiting (the caller must abort launch).
    private func terminateIfDuplicateInstance() -> Bool {
        let current = NSRunningApplication.current
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != current.processIdentifier }
        guard let existing = others.first else { return false }
        AppLog.log("Another instance (pid \(existing.processIdentifier)) is already running; activating it and exiting this one.")
        existing.activate()
        NSApp.terminate(nil)
        return true
    }

    /// Surfaces every settings-load problem so a bad config never fails silently.
    /// `SettingsLoadIssue` has three cases; the brief only anticipated
    /// `.corruptBackedUp`, so `.corruptBackupFailed`/`.readFailed` get the same
    /// NSLog+notify treatment here (deviation, documented in the task report).
    private func handleLoadIssue(_ issue: SettingsLoadIssue?) {
        guard let issue else { return }
        switch issue {
        case .corruptBackedUp(let backup):
            NSLog("Settings were corrupt; backed up to \(backup.path) and reset to defaults")
            effects.notify(title: "Settings reset",
                           body: "Corrupt settings backed up to \(backup.lastPathComponent)",
                           fileURL: nil)
        case .corruptBackupFailed(let reason):
            NSLog("Settings were corrupt and the backup failed (\(reason)); reset to defaults")
            effects.notify(title: "Settings reset",
                           body: "Corrupt settings could not be backed up: \(reason)",
                           fileURL: nil)
        case .readFailed(let reason):
            NSLog("Settings could not be read (\(reason)); using defaults")
            effects.notify(title: "Settings reset",
                           body: "Settings file could not be read: \(reason)",
                           fileURL: nil)
        }
    }

    private func registerHotkeys(_ config: HotkeySettings) {
        let manager = HotkeyManager()
        hotkeys = manager
        if let combo = config.fullscreen {
            manager.register(combo) { [weak self] in
                AppLog.log("Fullscreen hotkey fired")
                self?.coordinator?.captureFullscreen()
            }
        }
        if let combo = config.region {
            manager.register(combo) { [weak self] in self?.coordinator?.captureRegion() }
        }
        if let combo = config.window {
            manager.register(combo) { [weak self] in self?.coordinator?.captureWindow() }
        }
        if let combo = config.record {
            manager.register(combo) { [weak self] in
                AppLog.log("Record hotkey fired")
                self?.recordingCoordinator?.toggle(mode: .region)
            }
        }
        AppLog.log("Hotkeys registered (fullscreen=\(config.fullscreen != nil), region=\(config.region != nil), window=\(config.window != nil), record=\(config.record != nil))")
    }

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

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        if let summary = UploadActivity.shared.summary {
            menu.addItem(menuItem(summary + " — History…", #selector(showHistory)))
            if UploadActivity.shared.latest?.url != nil {
                menu.addItem(menuItem("Copy Last Upload Link", #selector(copyLastUploadLink)))
            }
            menu.addItem(.separator())
        }
        menu.addItem(menuItem("Capture Region", #selector(menuCaptureRegion)))
        menu.addItem(menuItem("Capture Window", #selector(menuCaptureWindow)))
        menu.addItem(menuItem("Capture Full Screen", #selector(menuCaptureFullscreen)))
        menu.addItem(.separator())
        buildRecordingItems(into: menu)
        menu.addItem(.separator())
        menu.addItem(menuItem("Open Captures Folder", #selector(openCapturesFolder)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Import .sxcu…", #selector(importSxcu)))
        menu.addItem(menuItem("Manage Destinations…", #selector(manageDestinations)))
        let uploadToggle = menuItem("Upload After Capture", #selector(toggleUploadAfterCapture))
        uploadToggle.state = currentUploadAfterCapture() ? .on : .off
        menu.addItem(uploadToggle)
        let annotateToggle = menuItem("Annotate Before Sharing", #selector(toggleAnnotateBeforeShare))
        annotateToggle.state = currentAnnotateBeforeShare() ? .on : .off
        menu.addItem(annotateToggle)
        menu.addItem(.separator())
        menu.addItem(menuItem("History…", #selector(showHistory)))
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showPreferences),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(menuItem("About Lumeshot", #selector(showAbout)))
        // Also in the main menu, but Lumeshot runs as an accessory app: that menu bar
        // only appears while Settings is open, so the status menu is the real home.
        menu.addItem(menuItem("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(NSMenuItem(title: "Quit Lumeshot",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
    }

    /// Adds the Record section: a "Start Recording" submenu (Region/Window/
    /// Display) while idle, or a "Stop Recording" item + a disabled elapsed-time
    /// item while recording, plus a "System Audio" toggle either way. Retains
    /// the elapsed item in `elapsedMenuItem` so the 1s Timer (`tickElapsed`) can
    /// mutate its title in place instead of tearing down the whole menu.
    private func buildRecordingItems(into menu: NSMenu) {
        let (settings, _) = SettingsStore(fileURL: SettingsStore.defaultFileURL).loadOrDefault()
        if recordingCoordinator?.isRecording == true {
            menu.addItem(menuItem("Stop Recording", #selector(menuStopRecording)))
            let elapsed = NSMenuItem(title: "● \(recordingStartedAt.map(elapsedLabel(since:)) ?? "0:00")",
                                     action: nil, keyEquivalent: "")
            elapsed.isEnabled = false
            elapsedMenuItem = elapsed
            menu.addItem(elapsed)
        } else {
            let start = NSMenuItem(title: "Start Recording", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.addItem(menuItem("Region", #selector(menuRecordRegion)))
            submenu.addItem(menuItem("Window", #selector(menuRecordWindow)))
            submenu.addItem(menuItem("Display", #selector(menuRecordDisplay)))
            start.submenu = submenu
            menu.addItem(start)
            elapsedMenuItem = nil
        }
        let audioToggle = menuItem("System Audio", #selector(toggleSystemAudio))
        audioToggle.state = settings.recording.systemAudio ? .on : .off
        menu.addItem(audioToggle)
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func menuCaptureRegion() { coordinator?.captureRegion() }
    @objc private func menuCaptureWindow() { coordinator?.captureWindow() }
    @objc private func menuCaptureFullscreen() {
        AppLog.log("Menu: Capture Full Screen clicked")
        coordinator?.captureFullscreen()
    }

    @objc private func menuRecordRegion() { recordingCoordinator?.toggle(mode: .region) }
    @objc private func menuRecordWindow() { recordingCoordinator?.toggle(mode: .window) }
    @objc private func menuRecordDisplay() { recordingCoordinator?.toggle(mode: .display) }
    @objc private func menuStopRecording() { recordingCoordinator?.stop() }

    @objc private func toggleSystemAudio() {
        let store = SettingsStore(fileURL: SettingsStore.defaultFileURL)
        do {
            // One transaction: this toggle reads, changes and writes the whole
            // settings document, and so does the SFTP host-key pin on a
            // background thread.
            let saved = try store.mutate { $0.recording.systemAudio.toggle() }
            AppLog.log("System audio recording: \(saved.recording.systemAudio)")
        } catch {
            AppLog.log("Failed to save system-audio toggle: \(error)")
        }
        rebuildMenu()
    }

    /// The single `onStateChange` handler for `RecordingCoordinator` (wired in
    /// Task 14): rebuilds the menu once, on the idle<->recording transition
    /// (to swap Start/Stop), and starts/stops the 1s elapsed ticker.
    private func updateRecordingUI(_ recording: Bool) {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartedAt = recording ? Date() : nil
        rebuildMenu()
        guard recording, let start = recordingStartedAt else {
            statusItem?.setRecording(false)
            return
        }
        statusItem?.setRecording(true)
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickElapsed(since: start) }
        }
    }

    private func elapsedLabel(since start: Date) -> String {
        let s = Int(Date().timeIntervalSince(start))
        return String(format: "%d:%02d", s/60, s%60)
    }

    /// Mutates the retained elapsed-time views directly — never calls
    /// `rebuildMenu()` here, so a live recording doesn't tear down/rebuild the
    /// whole NSMenu once a second.
    private func tickElapsed(since start: Date) {
        let label = elapsedLabel(since: start)
        elapsedMenuItem?.title = "● \(label)"
        statusItem?.setTitle(label)
    }

    private func currentUploadAfterCapture() -> Bool {
        SettingsStore(fileURL: SettingsStore.defaultFileURL).loadOrDefault().0.upload.uploadAfterCapture
    }

    private func currentAnnotateBeforeShare() -> Bool {
        SettingsStore(fileURL: SettingsStore.defaultFileURL).loadOrDefault().0.editor.annotateBeforeShare
    }

    @objc private func manageDestinations() { preferencesWindow?.show(selecting: .uploads) }

    @objc private func showPreferences() { preferencesWindow?.show() }

    @objc private func showAbout() { aboutWindow.show() }

    @objc private func checkForUpdates() { updaterController.checkForUpdates(nil) }

    @objc private func copyLastUploadLink() { UploadActivity.shared.copyLatestLink() }

    @objc private func showHistory() {
        guard let store = historyStore else {
            effects.notify(title: "History unavailable",
                           body: "The history database could not be opened.", fileURL: nil)
            return
        }
        if historyWindow == nil {
            historyWindow = HistoryWindowController(
                store: store, settingsStore: SettingsStore(fileURL: SettingsStore.defaultFileURL))
        }
        historyWindow?.show()
    }

    @objc private func importSxcu() {
        // runModal (synchronous, @MainActor) avoids the Swift 6 concurrency friction
        // of an escaping completion closure; UTType filtering avoids the deprecated
        // `allowedFileTypes` API (which would emit a build warning).
        let panel = NSOpenPanel()
        if let sxcuType = UTType(filenameExtension: "sxcu") {
            panel.allowedContentTypes = [sxcuType]
        } else {
            panel.allowsOtherFileTypes = true
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        performSxcuImport(from: url)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        performSxcuImport(from: URL(fileURLWithPath: filename))
        return true
    }

    private func performSxcuImport(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let store = SettingsStore(fileURL: SettingsStore.defaultFileURL)
            var (settings, _) = store.loadOrDefault()
            let id = UUID().uuidString
            let credentials = KeychainCredentialStore()
            let destination = try SxcuImporter.makeDestination(
                from: data, id: id, credentials: credentials)
            settings.upload = settings.upload.addingOrUpdating(destination)
            do {
                try store.save(settings)
            } catch {
                // The Keychain writes already happened inside makeDestination.
                // Without this the secrets would linger with no destination
                // referencing them, invisible and unreachable.
                _ = CredentialTransaction.purgeRestorable(destination.secretAccounts,
                                                          in: credentials)
                throw error
            }
            AppLog.log("Imported .sxcu destination '\(destination.name)' (id \(id))")
            effects.notify(title: "Uploader imported",
                           body: settings.upload.activeDestinationID == id
                               ? "\(destination.name) is now the active uploader."
                               : "\(destination.name) was added. Select the active uploader in Preferences → Uploads.",
                           fileURL: nil)
            rebuildMenu()
        } catch {
            AppLog.log("Import .sxcu failed: \(error)")
            effects.notify(title: "Import failed", body: "\(error)", fileURL: nil)
        }
    }

    @objc private func toggleUploadAfterCapture() {
        let store = SettingsStore(fileURL: SettingsStore.defaultFileURL)
        var (settings, _) = store.loadOrDefault()
        if !settings.upload.uploadAfterCapture && settings.upload.activeDestination == nil {
            effects.notify(title: "Choose an active uploader",
                           body: "Add and select an uploader in Preferences → Uploads first.", fileURL: nil)
            return
        }
        settings.upload = settings.upload.settingUploadAfterCapture(!settings.upload.uploadAfterCapture)
        do {
            try store.save(settings)
            AppLog.log("Upload after capture: \(settings.upload.uploadAfterCapture)")
        } catch {
            AppLog.log("Failed to save upload-after-capture toggle: \(error)")
        }
        rebuildMenu()
    }

    @objc private func toggleAnnotateBeforeShare() {
        let store = SettingsStore(fileURL: SettingsStore.defaultFileURL)
        do {
            let saved = try store.mutate { $0.editor.annotateBeforeShare.toggle() }
            AppLog.log("Annotate before sharing: \(saved.editor.annotateBeforeShare)")
        } catch {
            AppLog.log("Failed to save annotate-before-sharing toggle: \(error)")
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        statusItem?.setMenu(buildMenu())
    }

    @objc private func openCapturesFolder() {
        let store = SettingsStore(fileURL: SettingsStore.defaultFileURL)
        let (settings, _) = store.loadOrDefault()
        let path = (settings.captureSavePath as NSString).expandingTildeInPath
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            AppLog.log("Failed to create captures folder at \(path): \(error)")
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Debug/e2e hook: `open -n "Lumeshot.app" --args --capture fullscreen`
    /// captures and exits, so the flow is verifiable over ssh.
    private func handleCLIArguments() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--capture"), args.count > i + 1 else { return }
        switch args[i + 1] {
        case "fullscreen":
            coordinator?.captureFullscreen { count in
                NSLog("CLI capture finished (\(count) file(s)); terminating")
                // Give the notification a beat to post before exiting.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
            }
        case "region":
            coordinator?.captureRegion()
        case "window":
            coordinator?.captureWindow()
        default:
            NSLog("Unknown --capture mode: \(args[i + 1])")
        }
    }
}
