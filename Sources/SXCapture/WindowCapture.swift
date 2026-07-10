import AppKit
import ScreenCaptureKit

/// `frame` is in CoreGraphics global coordinates (origin top-left of primary display).
public struct WindowCandidate: Sendable, Equatable {
    public let windowID: UInt32
    public let title: String?
    public let appName: String?
    public let appBundleID: String?
    public let frame: CGRect
    public let layer: Int
    public let isOnScreen: Bool

    public init(windowID: UInt32, title: String?, appName: String?, appBundleID: String?,
                frame: CGRect, layer: Int, isOnScreen: Bool) {
        self.windowID = windowID
        self.title = title
        self.appName = appName
        self.appBundleID = appBundleID
        self.frame = frame
        self.layer = layer
        self.isOnScreen = isOnScreen
    }
}

/// Backing scale of the screen most overlapping the given CG-global rect
/// (top-left origin), converting to AppKit coords for the comparison.
@MainActor
private func backingScale(forCGGlobalFrame frame: CGRect) -> CGFloat {
    guard let primaryHeight = NSScreen.screens.first?.frame.height else { return 2 }
    let appKit = CGRect(x: frame.origin.x,
                        y: primaryHeight - frame.origin.y - frame.height,
                        width: frame.width, height: frame.height)
    let best = NSScreen.screens.max { a, b in
        a.frame.intersection(appKit).area < b.frame.intersection(appKit).area
    }
    return best?.backingScaleFactor ?? 2
}

private extension CGRect {
    var area: CGFloat { width * height }
}

public enum WindowFilter {
    /// Pickable windows: normal layer, on screen, big enough to be intentional,
    /// owned by an identifiable app, not ourselves. Sorted by area descending so
    /// hit-testing (last match wins) picks the smallest window under the cursor.
    public static func selectable(from windows: [WindowCandidate],
                                  excludingBundleID: String?) -> [WindowCandidate] {
        windows.filter { w in
            w.layer == 0
                && w.isOnScreen
                && w.frame.width >= 50 && w.frame.height >= 50
                && (w.appName != nil || w.title != nil)
                && (excludingBundleID == nil || w.appBundleID != excludingBundleID)
        }
        .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
    }
}

@MainActor
public enum WindowCapture {
    public static func candidates(excludingBundleID: String?) async throws -> [WindowCandidate] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        let mapped = content.windows.map { w in
            WindowCandidate(windowID: w.windowID,
                            title: w.title,
                            appName: w.owningApplication?.applicationName,
                            appBundleID: w.owningApplication?.bundleIdentifier,
                            frame: w.frame,
                            layer: w.windowLayer,
                            isOnScreen: w.isOnScreen)
        }
        return WindowFilter.selectable(from: mapped, excludingBundleID: excludingBundleID)
    }

    public static func capture(windowID: UInt32) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.noMatchingWindow
        }
        let scale = backingScale(forCGGlobalFrame: window.frame)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB   // spec §3.1: export in sRGB
        return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                          configuration: config)
    }
}
