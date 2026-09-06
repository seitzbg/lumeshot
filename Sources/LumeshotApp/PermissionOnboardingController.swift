import AppKit
import LumeshotCapture

@MainActor
final class PermissionOnboardingController: NSObject {
    private static var shared: PermissionOnboardingController?
    private var window: NSWindow?

    /// Current Screen Recording grant state, without side effects.
    static func isGranted() -> Bool {
        CapturePermission.preflight()
    }

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
        // The last paragraph exists because of a real failure mode: macOS keys
        // this grant to the app's code-signing identity, so a differently-signed
        // copy of Lumeshot (a dev build next to a release) leaves the toggle
        // showing ON while the running copy is denied. Without the hint, the
        // user grants, relaunches, and is asked again — indefinitely.
        let text = NSTextField(wrappingLabelWithString: """
        Lumeshot needs the Screen Recording permission to capture your screen.

        1. Click "Open System Settings" below.
        2. Enable "Lumeshot" under Screen & System Audio Recording.
        3. Click "Relaunch" — macOS applies this permission at app launch.

        Already enabled but still seeing this? Toggle Lumeshot off and on again. \
        macOS ties the grant to the exact app binary, so a reinstalled or \
        differently-signed copy needs it re-granted.
        """)
        text.frame = NSRect(x: 20, y: 70, width: 380, height: 190)

        let openButton = NSButton(title: "Open System Settings",
                                  target: self, action: #selector(openSettings))
        openButton.frame = NSRect(x: 20, y: 20, width: 180, height: 32)
        let relaunchButton = NSButton(title: "Relaunch",
                                      target: self, action: #selector(relaunch))
        relaunchButton.frame = NSRect(x: 210, y: 20, width: 100, height: 32)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
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
        // `open -n` immediately followed by terminate() raced the
        // duplicate-instance guard: the new process could start while this one
        // was still registered, decide it was the duplicate, and exit -- then
        // this one exited too, leaving nothing running. Wait for this PID to
        // actually go away before launching.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", """
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done
            exec /usr/bin/open -n "$1"
            """, "sh", bundlePath]
        do {
            try task.run()
        } catch {
            NSLog("Relaunch failed: \(error)")
            NSSound.beep()
            return   // keep the app alive; user can relaunch manually
        }
        NSApp.terminate(nil)
    }
}
