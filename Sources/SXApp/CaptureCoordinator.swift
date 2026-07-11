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
    private let uploadService: UploadService
    private let historyStore: HistoryStore?
    private var regionSession: RegionOverlaySession?
    private var regionCaptureInFlight = false
    private var windowSession: WindowPickerSession?
    private var windowCaptureInFlight = false

    init(settingsStore: SettingsStore, effects: AppPipelineEffects,
         uploadService: UploadService, historyStore: HistoryStore?) {
        self.settingsStore = settingsStore
        self.effects = effects
        self.uploadService = uploadService
        self.historyStore = historyStore
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
        AppLog.log("captureWindow invoked; preflight=\(PermissionOnboardingController.isGranted())")
        guard PermissionOnboardingController.ensurePermission() else {
            AppLog.log("captureWindow aborted: Screen Recording not granted")
            return
        }
        guard !windowCaptureInFlight, windowSession == nil else { return }  // one overlay at a time
        windowCaptureInFlight = true
        Task { @MainActor in
            do {
                let candidates = try await WindowCapture.candidates(
                    excludingBundleID: Bundle.main.bundleIdentifier)
                AppLog.log("WindowCapture.candidates returned \(candidates.count) candidate(s)")
                guard !candidates.isEmpty else {
                    AppLog.log("Window capture: no capturable windows found")
                    self.effects.notify(title: "No windows to capture",
                                        body: "No capturable windows were found.", fileURL: nil)
                    self.windowCaptureInFlight = false
                    return
                }
                let session = WindowPickerSession(candidates: candidates) { [weak self] pick in
                    self?.windowSession = nil
                    self?.windowCaptureInFlight = false
                    if let pick {
                        AppLog.log("Window picked: \(pick.appName ?? "?") — \(pick.title ?? "Untitled")")
                        Task { @MainActor in
                            do {
                                let image = try await WindowCapture.capture(windowID: pick.windowID)
                                self?.deliver(image: image, appName: pick.appName)
                            } catch {
                                self?.reportFailure(error)
                            }
                        }
                    } else {
                        AppLog.log("Window capture cancelled")
                    }
                }
                self.windowSession = session
                session.begin()
            } catch {
                self.windowCaptureInFlight = false
                self.reportFailure(error)
            }
        }
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
            recordAndMaybeUpload(settings: settings, savedURL: result.savedURL,
                                 pngData: png, capturedAt: artifact.capturedAt)
            return true
        } catch {
            reportFailure(error)
            return false
        }
    }

    /// Records a history row for the capture, then (if configured) uploads
    /// asynchronously and updates the row with the URL or a failure marker.
    /// Runs after the synchronous disk save, preserving the local-first invariant.
    private func recordAndMaybeUpload(settings: AppSettings, savedURL: URL?,
                                      pngData: Data, capturedAt: Date) {
        let entryID = UUID().uuidString
        let destination = settings.upload.activeDestination
        let willUpload = settings.upload.uploadAfterCapture && destination != nil

        if let store = historyStore {
            let entry = HistoryEntry(id: entryID, capturedAt: capturedAt,
                                     filePath: savedURL?.path, url: nil, deletionURL: nil,
                                     // Only attribute a destination when we actually upload to it.
                                     destinationName: willUpload ? destination?.name : nil,
                                     uploadFailed: false)
            do { try store.insert(entry) } catch { AppLog.log("History insert failed: \(error)") }
        }

        guard willUpload, let destination else { return }
        let filename = savedURL?.lastPathComponent ?? "capture.png"
        Task { @MainActor in
            do {
                let uploader = try uploadService.uploader(for: destination)
                let file = UploadService.filePart(pngData: pngData, filename: filename)
                let result = try await uploader.upload(file)
                AppLog.log("Upload succeeded: \(result.url)")
                effects.copyTextToClipboard(result.url)
                effects.notifyURL(title: "Uploaded", body: result.url, url: result.url)
                updateHistory(id: entryID, url: result.url, deletionURL: result.deletionURL,
                              failed: false)
            } catch {
                AppLog.log("Upload failed: \(error)")
                effects.notify(title: "Upload failed",
                               body: "\(error). Local file kept.", fileURL: savedURL)
                updateHistory(id: entryID, url: nil, deletionURL: nil, failed: true)
            }
        }
    }

    /// Applies the upload outcome to the history row, logging rather than
    /// swallowing a store failure (fail-loud).
    private func updateHistory(id: String, url: String?, deletionURL: String?, failed: Bool) {
        do {
            try historyStore?.setURL(id: id, url: url, deletionURL: deletionURL, failed: failed)
        } catch {
            AppLog.log("History update failed for \(id): \(error)")
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
