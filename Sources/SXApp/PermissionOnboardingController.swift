import AppKit
import SXCapture

@MainActor
final class PermissionOnboardingController: NSObject {
    private static var shared: PermissionOnboardingController?
    private var window: NSWindow?

    /// True if Screen Recording is granted. Otherwise prompts (first run) and
    /// shows the onboarding window; the caller must abort the capture attempt.
    static func ensurePermission() -> Bool {
        if CapturePermission.preflight() { return true }
        CapturePermission.request()   // triggers the one-time system dialog
        let controller = shared ?? PermissionOnboardingController()
        shared = controller
        controller.show()
        return false
    }

    private func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let text = NSTextField(wrappingLabelWithString: """
        ShareX for Mac needs the Screen Recording permission to capture your screen.

        1. Click "Open System Settings" below.
        2. Enable "ShareX for Mac" under Screen & System Audio Recording.
        3. Click "Relaunch" — macOS applies this permission at app launch.
        """)
        text.frame = NSRect(x: 20, y: 70, width: 380, height: 130)

        let openButton = NSButton(title: "Open System Settings",
                                  target: self, action: #selector(openSettings))
        openButton.frame = NSRect(x: 20, y: 20, width: 180, height: 32)
        let relaunchButton = NSButton(title: "Relaunch",
                                      target: self, action: #selector(relaunch))
        relaunchButton.frame = NSRect(x: 210, y: 20, width: 100, height: 32)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Screen Recording Permission"
        w.contentView?.addSubview(text)
        w.contentView?.addSubview(openButton)
        w.contentView?.addSubview(relaunchButton)
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func openSettings() {
        CapturePermission.openSystemSettings()
    }

    @objc private func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
