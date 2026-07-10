import AppKit
import SXCapture
import SXCore

@MainActor
final class CaptureCoordinator {
    private let settings: AppSettings
    private let effects: AppPipelineEffects

    init(settings: AppSettings, effects: AppPipelineEffects) {
        self.settings = settings
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
                    self.deliver(image: display.image, appName: appName)
                    count += 1
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

    func deliver(image: CGImage, appName: String?) {
        guard let png = ImageEncoder.png(from: image) else {
            NSLog("PNG encoding failed")
            return
        }
        let artifact = CaptureArtifact(pngData: png, width: image.width, height: image.height,
                                       capturedAt: Date(), appName: appName)
        do {
            let result = try AfterCapturePipeline(settings: settings, effects: effects)
                .process(artifact)
            NSLog("Capture delivered: \(result.savedURL?.path ?? "clipboard only")")
        } catch {
            reportFailure(error)
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
