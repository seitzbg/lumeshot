import AppKit
import SXCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var hotkeys: HotkeyManager?
    private var coordinator: CaptureCoordinator?
    private let effects = AppPipelineEffects()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        let uploadService = UploadService(credentials: KeychainCredentialStore())
        let coordinator = CaptureCoordinator(settingsStore: store, effects: effects,
                                             uploadService: uploadService,
                                             historyStore: historyStore)
        self.coordinator = coordinator
        statusItem = StatusItemController(menu: buildMenu())
        registerHotkeys(settings.hotkeys)
        AppLog.log("Launched (bundle: \(Bundle.main.bundleIdentifier ?? "none"), screenRecording=\(PermissionOnboardingController.isGranted()))")

        handleCLIArguments()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys?.unregisterAll()
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
        menu.addItem(menuItem("Open Captures Folder", #selector(openCapturesFolder)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Import .sxcu…", #selector(importSxcu)))
        let uploadToggle = menuItem("Upload After Capture", #selector(toggleUploadAfterCapture))
        uploadToggle.state = currentUploadAfterCapture() ? .on : .off
        menu.addItem(uploadToggle)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ShareX for Mac",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
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

    private func currentUploadAfterCapture() -> Bool {
        SettingsStore(fileURL: SettingsStore.defaultFileURL).loadOrDefault().0.upload.uploadAfterCapture
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
