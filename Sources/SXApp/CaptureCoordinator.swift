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
        guard PermissionOnboardingController.ensurePermission() else {
            completion?(0)
            return
        }
        let appName = frontmostAppName()
        Task { @MainActor in
            do {
                let displays = try await DisplayCapture.captureAllDisplays(showCursor: false)
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
        // Replaced with the region overlay session in Task 11.
        NSLog("Region capture not implemented yet")
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
            NSLog("Capture delivered: \(result.savedURL?.path ?? "clipboard only")")
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
        NSLog("Capture failed: \(error)")
        effects.notify(title: "Capture failed", body: error.localizedDescription, fileURL: nil)
    }
}
