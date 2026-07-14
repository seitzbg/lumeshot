import AppKit
import CoreGraphics

@MainActor
public enum CapturePermission {
    /// True if Screen Recording is already granted.
    public static func preflight() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the one-time system prompt; returns current grant state.
    @discardableResult
    public static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static func openSystemSettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
