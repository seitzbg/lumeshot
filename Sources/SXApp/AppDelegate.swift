import AppKit
import SXCore

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
            try? store.save(settings)   // materialize defaults for hand-editing
        }

        effects.setUpNotifications()
        let coordinator = CaptureCoordinator(settings: settings, effects: effects)
        self.coordinator = coordinator
        statusItem = StatusItemController(menu: buildMenu())
        registerHotkeys(settings.hotkeys)
        NSLog("ShareX for Mac launched (bundle: \(Bundle.main.bundleIdentifier ?? "none"))")

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
            manager.register(combo) { [weak self] in self?.coordinator?.captureFullscreen() }
        }
        if let combo = config.region {
            manager.register(combo) { [weak self] in self?.coordinator?.captureRegion() }
        }
        if let combo = config.window {
            manager.register(combo) { [weak self] in self?.coordinator?.captureWindow() }
        }
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Capture Region", #selector(menuCaptureRegion)))
        menu.addItem(menuItem("Capture Window", #selector(menuCaptureWindow)))
        menu.addItem(menuItem("Capture Full Screen", #selector(menuCaptureFullscreen)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Open Captures Folder", #selector(openCapturesFolder)))
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
    @objc private func menuCaptureFullscreen() { coordinator?.captureFullscreen() }

    @objc private func openCapturesFolder() {
        let store = SettingsStore(fileURL: SettingsStore.defaultFileURL)
        let (settings, _) = store.loadOrDefault()
        let path = (settings.captureSavePath as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
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
