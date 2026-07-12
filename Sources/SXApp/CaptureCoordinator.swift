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
    private let editorPresenter: EditorPresenting?
    private var regionSession: RegionOverlaySession?
    private var regionCaptureInFlight = false
    private var windowSession: WindowPickerSession?
    private var windowCaptureInFlight = false

    init(settingsStore: SettingsStore, effects: AppPipelineEffects,
         uploadService: UploadService, historyStore: HistoryStore?,
         editorPresenter: EditorPresenting? = nil) {
        self.settingsStore = settingsStore
        self.effects = effects
        self.uploadService = uploadService
        self.historyStore = historyStore
        self.editorPresenter = editorPresenter
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
                guard !displays.isEmpty else { completion?(0); return }
                // Count only persisted images. deliver reports its outcome asynchronously
                // when annotate-before-share routes through the editor, so aggregate via a
                // main-actor pending counter (no data race — all on @MainActor).
                var count = 0
                var pending = displays.count
                for display in displays {
                    self.deliver(image: display.image, appName: appName) { persisted in
                        if persisted { count += 1 }
                        pending -= 1
                        if pending == 0 { completion?(count) }
                    }
                }
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

    /// Routes a captured image to the editor (when annotate-before-share is on) or
    /// straight to persistence. `onOutcome(true)` means the image was persisted to disk
    /// (Save/Upload); `onOutcome(false)` means it was not (Copy/Cancel/discard), so
    /// callers can count only persisted files.
    func deliver(image: CGImage, appName: String?, onOutcome: (@MainActor (Bool) -> Void)? = nil) {
        let (settings, _) = settingsStore.loadOrDefault()
        if settings.editor.annotateBeforeShare, let presenter = editorPresenter {
            presenter.present(image: image) { [weak self] result in
                guard let self else { onOutcome?(false); return }
                switch result {
                case nil:
                    AppLog.log("Editor cancelled; capture discarded before save")
                    onOutcome?(false)
                case .some(let r):
                    switch r.action {
                    case .save:
                        onOutcome?(self.finishPersist(image: r.image, appName: appName, upload: false))
                    case .upload:
                        onOutcome?(self.finishPersist(image: r.image, appName: appName, upload: true))
                    case .copy:
                        self.copyImageToClipboard(r.image)
                        AppLog.log("Editor copy: image on clipboard, not persisted")
                        onOutcome?(false)
                    }
                }
            }
            return
        }
        // Passthrough (annotate off): preserve M3a behavior — upload iff configured.
        onOutcome?(finishPersist(image: image, appName: appName,
                                 upload: settings.upload.uploadAfterCapture))
    }

    /// Persists the (possibly edited) image: encodes PNG, saves to disk, records a
    /// history row, and — only when `upload` is true — uploads and puts the URL on the
    /// clipboard. Local-first invariant: the disk save precedes any upload. Returns
    /// true when the image was persisted (disk save succeeded).
    @discardableResult
    private func finishPersist(image: CGImage, appName: String?, upload: Bool) -> Bool {
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
                                 pngData: png, capturedAt: artifact.capturedAt, upload: upload)
            return true
        } catch {
            reportFailure(error)
            return false
        }
    }

    /// Puts the annotated image on the clipboard without touching disk or history.
    /// Copy is deliberately ephemeral (ratified action design): no file is written.
    private func copyImageToClipboard(_ image: CGImage) {
        guard let png = ImageEncoder.png(from: image) else {
            reportFailure(DeliveryError.pngEncodingFailed)
            return
        }
        effects.copyImageToClipboard(png)
    }

    /// Records a history row for the capture, then (if configured) uploads
    /// asynchronously and updates the row with the URL or a failure marker.
    /// Runs after the synchronous disk save, preserving the local-first invariant.
    private func recordAndMaybeUpload(settings: AppSettings, savedURL: URL?,
                                      pngData: Data, capturedAt: Date, upload: Bool) {
        let entryID = UUID().uuidString
        let destination = settings.upload.activeDestination
        // The action (Save vs Upload) now decides whether to upload; the passthrough
        // path passes `settings.upload.uploadAfterCapture` so its behavior is unchanged.
        let willUpload = upload && destination != nil

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
