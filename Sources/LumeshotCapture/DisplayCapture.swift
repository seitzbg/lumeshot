import AppKit
// @preconcurrency: on the Xcode 16 / macOS 15 SDK, SCShareableContent is not
// Sendable, so awaiting its factory methods from @MainActor errors under Swift 6
// strict concurrency. Newer SDKs annotate it correctly; this keeps both building.
@preconcurrency import ScreenCaptureKit

/// A display frozen at capture time. `screenFrame` is in AppKit screen coordinates (points).
public struct FrozenDisplay: @unchecked Sendable {   // CGImage is immutable; safe to pass
    public let displayID: CGDirectDisplayID
    public let screenFrame: CGRect
    public let image: CGImage
    public let scale: CGFloat
}

public enum CaptureError: Error, LocalizedError {
    case noDisplays
    case noMatchingWindow
    public var errorDescription: String? {
        switch self {
        case .noDisplays: return "No shareable displays found."
        case .noMatchingWindow: return "The selected window is no longer available."
        }
    }
}

@MainActor
public enum DisplayCapture {
    public static func captureAllDisplays(showCursor: Bool) async throws -> [FrozenDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else { throw CaptureError.noDisplays }

        var result: [FrozenDisplay] = []
        for display in content.displays {
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                    == display.displayID
            }
            if screen == nil {
                NSLog("No NSScreen match for display \(display.displayID); using fallback scale/frame")
            }
            let scale = screen?.backingScaleFactor ?? 2
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = showCursor
            config.colorSpaceName = CGColorSpace.sRGB   // spec §3.1: export in sRGB
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            result.append(FrozenDisplay(
                displayID: display.displayID,
                screenFrame: screen?.frame
                    ?? CGRect(x: 0, y: 0, width: display.width, height: display.height),
                image: image,
                scale: scale))
        }
        return result
    }

    /// Fresh shareable-content snapshot, exposing the raw SCK objects that
    /// `captureAllDisplays` deliberately hides behind `FrozenDisplay`. Recording
    /// (M4) needs the live `SCDisplay` to build an `SCContentFilter`.
    public static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Resolves the `SCDisplay` matching `displayID` from a `shareableContent()` snapshot.
    public static func scDisplay(for displayID: CGDirectDisplayID,
                                 in content: SCShareableContent) -> SCDisplay? {
        content.displays.first { $0.displayID == displayID }
    }
}
