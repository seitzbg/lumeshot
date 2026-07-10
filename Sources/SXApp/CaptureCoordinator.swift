import AppKit
import SXCapture
import SXCore

enum DeliveryError: Error, LocalizedError {
    case pngEncodingFailed
    var errorDescription: String? { "Could not encode the capture as PNG." }
}

@MainActor
final class CaptureCoordinator {
    private let settingsStore: SettingsStore
    private let effects: AppPipelineEffects
    private var regionSession: RegionOverlaySession?
    private var regionCaptureInFlight = false

    init(settingsStore: SettingsStore, effects: AppPipelineEffects) {
        self.settingsStore = settingsStore
        self.effects = effects
    }

    func captureFullscreen() {
        captureFullscreen(completion: nil)
    }

    /// Captures every display, one artifact per display. Clipboard/notification
    /// effects run per artifact; the last one wins the clipboard (single-display
    /// systems are unaffected). Completion reports how many files were produced.
    func captureFullscreen(completion: (@MainActor (Int) -> Void)?) {
        AppLog.log("captureFullscreen invoked; preflight=\(PermissionOnboardingController.isGranted())")
        guard PermissionOnboardingController.ensurePermission() else {
            AppLog.log("captureFullscreen aborted: Screen Recording not granted")
            completion?(0)
            return
        }
        let appName = frontmostAppName()
        Task { @MainActor in
            do {
                let displays = try await DisplayCapture.captureAllDisplays(showCursor: false)
                AppLog.log("captureAllDisplays returned \(displays.count) display(s)")
                var count = 0
                for display in displays {
                    if self.deliver(image: display.image, appName: appName) {
                        count += 1
                    }
                }
                completion?(count)
            } catch {
                self.reportFailure(error)
                completion?(0)
            }
        }
    }

    func captureRegion() {
        AppLog.log("captureRegion invoked; preflight=\(PermissionOnboardingController.isGranted())")
        guard PermissionOnboardingController.ensurePermission() else {
            AppLog.log("captureRegion aborted: Screen Recording not granted")
            return
        }
        guard !regionCaptureInFlight, regionSession == nil else { return }  // one overlay at a time
        regionCaptureInFlight = true
        let appName = frontmostAppName()
        Task { @MainActor in
            do {
                let displays = try await DisplayCapture.captureAllDisplays(showCursor: false)
                AppLog.log("captureAllDisplays returned \(displays.count) display(s) for region overlay")
                let session = RegionOverlaySession(displays: displays) { [weak self] image in
                    self?.regionSession = nil
                    self?.regionCaptureInFlight = false
                    if let image {
                        self?.deliver(image: image, appName: appName)
                    } else {
                        AppLog.log("Region capture cancelled")
                    }
                }
                self.regionSession = session
                session.begin()
            } catch {
                self.regionCaptureInFlight = false
                self.reportFailure(error)
            }
        }
    }

    func captureWindow() {
        // Replaced with the window picker session in Task 12.
        NSLog("Window capture not implemented yet")
    }

    @discardableResult
    func deliver(image: CGImage, appName: String?) -> Bool {
        guard let png = ImageEncoder.png(from: image) else {
            reportFailure(DeliveryError.pngEncodingFailed)
            return false
        }
        let artifact = CaptureArtifact(pngData: png, width: image.width, height: image.height,
                                       capturedAt: Date(), appName: appName)
        // Settings are reloaded fresh here (not the launch-time snapshot) so hand-edits
        // to settings.json take effect on the next capture; per-capture reload
        // deliberately ignores the load-issue channel (already reported at launch).
        let (settings, _) = settingsStore.loadOrDefault()
        do {
            let result = try AfterCapturePipeline(settings: settings, effects: effects)
                .process(artifact)
            AppLog.log("Capture delivered: \(result.savedURL?.path ?? "clipboard only")")
            return true
        } catch {
            reportFailure(error)
            return false
        }
    }

    func frontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    private func reportFailure(_ error: Error) {
        AppLog.log("Capture failed: \(error)")
        effects.notify(title: "Capture failed", body: error.localizedDescription, fileURL: nil)
    }
}
