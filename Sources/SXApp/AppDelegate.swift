import AppKit
import SXCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var hotkeys: HotkeyManager?
    private var coordinator: CaptureCoordinator?
    private var destinationsWindow: DestinationsWindowController?
    private var historyStore: HistoryStore?
    private var historyWindow: HistoryWindowController?
    private let editorWindow = EditorWindowController()
    private let effects = AppPipelineEffects()
    private var recordingCoordinator: RecordingCoordinator?
    private var elapsedMenuItem: NSMenuItem?
    private var elapsedTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !terminateIfDuplicateInstance() else { return }
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
        let uploadService = UploadService(credentials: KeychainCredentialStore())
        let coordinator = CaptureCoordinator(settingsStore: store, effects: effects,
                                             uploadService: uploadService,
                                             historyStore: historyStore,
                                             editorPresenter: editorWindow)
        self.coordinator = coordinator
        destinationsWindow = DestinationsWindowController(
            store: store, credentials: KeychainCredentialStore(),
            onChange: { [weak self] in self?.rebuildMenu() })
        statusItem = StatusItemController(menu: buildMenu())
        registerHotkeys(settings.hotkeys)
        AppLog.log("Launched (bundle: \(Bundle.main.bundleIdentifier ?? "none"), screenRecording=\(PermissionOnboardingController.isGranted()))")

        handleCLIArguments()
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
        AppLog.log("Hotkeys registered (fullscreen=\(config.fullscreen != nil), region=\(config.region != nil), window=\(config.window != nil))")
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
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
        menu.addItem(NSMenuItem(title: "Quit ShareX for Mac",
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
            let elapsed = NSMenuItem(title: "● 0:00", action: nil, keyEquivalent: "")
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
        var (settings, _) = store.loadOrDefault()
        settings.recording.systemAudio.toggle()
        do {
            try store.save(settings)
            AppLog.log("System audio recording: \(settings.recording.systemAudio)")
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
        rebuildMenu()
        guard recording else {
            statusItem?.setRecording(false)
            return
        }
        statusItem?.setRecording(true)
        let start = Date()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickElapsed(since: start) }
        }
    }

    /// Mutates the retained elapsed-time views directly — never calls
    /// `rebuildMenu()` here, so a live recording doesn't tear down/rebuild the
    /// whole NSMenu once a second.
    private func tickElapsed(since start: Date) {
        let seconds = Int(Date().timeIntervalSince(start))
        let label = String(format: "%d:%02d", seconds / 60, seconds % 60)
        elapsedMenuItem?.title = "● \(label)"
        statusItem?.setTitle(label)
    }

    private func currentUploadAfterCapture() -> Bool {
        SettingsStore(fileURL: SettingsStore.defaultFileURL).loadOrDefault().0.upload.uploadAfterCapture
    }

    private func currentAnnotateBeforeShare() -> Bool {
        SettingsStore(fileURL: SettingsStore.defaultFileURL).loadOrDefault().0.editor.annotateBeforeShare
    }

    @objc private func manageDestinations() { destinationsWindow?.show() }

    @objc private func showHistory() {
        guard let store = historyStore else {
            effects.notify(title: "History unavailable",
                           body: "The history database could not be opened.", fileURL: nil)
            return
        }
        if historyWindow == nil { historyWindow = HistoryWindowController(store: store) }
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
            let destination = try SxcuImporter.makeDestination(
                from: data, id: id, credentials: KeychainCredentialStore())
            settings.upload.destinations.append(destination)
            settings.upload.activeDestinationID = id      // make the freshly imported one active
            try store.save(settings)
            AppLog.log("Imported .sxcu destination '\(destination.name)' (id \(id))")
            effects.notify(title: "Uploader imported",
                           body: "\(destination.name) is now the active destination.",
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
        settings.upload.uploadAfterCapture.toggle()
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
        var (settings, _) = store.loadOrDefault()
        settings.editor.annotateBeforeShare.toggle()
        do {
            try store.save(settings)
            AppLog.log("Annotate before sharing: \(settings.editor.annotateBeforeShare)")
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

    /// Debug/e2e hook: `open -n "ShareX for Mac.app" --args --capture fullscreen`
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
