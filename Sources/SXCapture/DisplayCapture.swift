import AppKit
import ScreenCaptureKit

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
}
