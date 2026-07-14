import AppKit
import AVFoundation
// @preconcurrency: see LumeshotCapture/DisplayCapture.swift for why.
@preconcurrency import ScreenCaptureKit
import LumeshotCapture
import LumeshotCore
import LumeshotRecord

@MainActor
final class RecordingCoordinator {
    enum Mode { case region, window, display }

    private let recorder: ScreenRecorder
    private let settingsStore: SettingsStore
    private let effects: any PipelineEffects
    private let deliver: @MainActor (URL, String?) -> Void
    private let onStateChange: @MainActor (Bool) -> Void
    private var isPresentingOverlay = false
    private var regionSession: RecordingRegionSession?
    private var windowSession: WindowPickerSession?

    init(recorder: ScreenRecorder, settingsStore: SettingsStore, effects: any PipelineEffects,
        deliver: @escaping @MainActor (URL, String?) -> Void,
        onStateChange: @escaping @MainActor (Bool) -> Void) {
        self.recorder = recorder
        self.settingsStore = settingsStore
        self.effects = effects
        self.deliver = deliver
        self.onStateChange = onStateChange
    }

    var isRecording: Bool { recorder.state == .recording }

    func toggle(mode: Mode) {
        if isRecording { stop() } else { start(mode: mode) }
    }

    func start(mode: Mode) {
        guard !isRecording, !isPresentingOverlay else { return }
        guard PermissionOnboardingController.ensurePermission() else {
            AppLog.log("Recording start aborted: Screen Recording not granted")
            return
        }
        switch mode {
        case .display: startDisplay()
        case .region: startRegion()
        case .window: startWindow()
        }
    }

    func stop() {
        guard isRecording else { return }
        Task { @MainActor in await recorder.stop() }
    }

    // MARK: - Display

    private func startDisplay() {
        isPresentingOverlay = true
        Task { @MainActor in
            defer { isPresentingOverlay = false }
            do {
                let content = try await DisplayCapture.shareableContent()
                guard let target = displayUnderMouse(in: content) ?? content.displays.first else {
                    AppLog.log("Recording: no displays available")
                    return
                }
                let screen = NSScreen.screens.first {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                        == target.displayID
                }
                let scale = screen?.backingScaleFactor ?? 2
                let pointSize = screen?.frame.size
                    ?? CGSize(width: CGFloat(target.width), height: CGFloat(target.height))
                let filter = SCContentFilter(display: target, excludingWindows: [])
                let dims = RecordingDimensions.display(pointWidth: pointSize.width,
                                                       pointHeight: pointSize.height, scale: scale)
                try await beginRecording(filter: filter, dimensions: dims, appName: nil)
            } catch {
                AppLog.log("Recording: display resolution failed: \(error)")
                effects.notify(title: "Recording failed", body: error.localizedDescription, fileURL: nil)
            }
        }
    }

    /// v1: the display containing the mouse cursor, so "Record Display" without
    /// a chooser does the least-surprising thing on a multi-monitor setup.
    private func displayUnderMouse(in content: SCShareableContent) -> SCDisplay? {
        let mouseLocation = NSEvent.mouseLocation
        guard let hovered = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }),
              let id = hovered.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }
        return DisplayCapture.scDisplay(for: id, in: content)
    }

    // MARK: - Region

    private func startRegion() {
        isPresentingOverlay = true
        Task { @MainActor in
            do {
                let displays = try await DisplayCapture.captureAllDisplays(showCursor: false)
                let session = RecordingRegionSession(displays: displays) { [weak self] picked in
                    self?.regionSession = nil
                    self?.isPresentingOverlay = false
                    guard let self, let picked else {
                        AppLog.log("Region recording cancelled")
                        return
                    }
                    Task { @MainActor in await self.startRegionRecording(picked) }
                }
                self.regionSession = session
                session.begin()
            } catch {
                isPresentingOverlay = false
                AppLog.log("Recording: region overlay setup failed: \(error)")
                effects.notify(title: "Recording failed", body: error.localizedDescription, fileURL: nil)
            }
        }
    }

    private func startRegionRecording(_ picked: (display: FrozenDisplay, rect: CGRect)) async {
        do {
            let content = try await DisplayCapture.shareableContent()
            guard let scDisplay = DisplayCapture.scDisplay(for: picked.display.displayID, in: content) else {
                AppLog.log("Recording: display \(picked.display.displayID) no longer available")
                return
            }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let dims = RecordingDimensions.region(rectInPoints: picked.rect, scale: picked.display.scale)
            try await beginRecording(filter: filter, dimensions: dims, appName: nil)
        } catch {
            AppLog.log("Recording: region start failed: \(error)")
            effects.notify(title: "Recording failed", body: error.localizedDescription, fileURL: nil)
        }
    }

    // MARK: - Window

    private func startWindow() {
        isPresentingOverlay = true
        Task { @MainActor in
            do {
                let candidates = try await WindowCapture.candidates(
                    excludingBundleID: Bundle.main.bundleIdentifier)
                guard !candidates.isEmpty else {
                    isPresentingOverlay = false
                    effects.notify(title: "No windows to record",
                                   body: "No capturable windows were found.", fileURL: nil)
                    return
                }
                let session = WindowPickerSession(candidates: candidates) { [weak self] pick in
                    self?.windowSession = nil
                    self?.isPresentingOverlay = false
                    guard let self, let pick else {
                        AppLog.log("Window recording cancelled")
                        return
                    }
                    Task { @MainActor in await self.startWindowRecording(pick) }
                }
                self.windowSession = session
                session.begin()
            } catch {
                isPresentingOverlay = false
                AppLog.log("Recording: window candidates failed: \(error)")
                effects.notify(title: "Recording failed", body: error.localizedDescription, fileURL: nil)
            }
        }
    }

    private func startWindowRecording(_ pick: WindowCandidate) async {
        do {
            let content = try await DisplayCapture.shareableContent()
            guard let scWindow = WindowCapture.scWindow(for: pick.windowID, in: content) else {
                AppLog.log("Recording: window \(pick.windowID) no longer available")
                return
            }
            let scale = backingScale(forCGGlobalFrame: pick.frame)
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let dims = RecordingDimensions.window(pointWidth: pick.frame.width,
                                                  pointHeight: pick.frame.height, scale: scale)
            try await beginRecording(filter: filter, dimensions: dims, appName: pick.appName)
        } catch {
            AppLog.log("Recording: window start failed: \(error)")
            effects.notify(title: "Recording failed", body: error.localizedDescription, fileURL: nil)
        }
    }

    // MARK: - Shared start + output URL

    private func beginRecording(filter: SCContentFilter, dimensions: RecordingDimensions,
                                appName: String?) async throws {
        let settings = settingsStore.loadOrDefault().0
        let dir = URL(fileURLWithPath: (settings.captureSavePath as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = RecordingDelivery.outputURL(settings: settings, capturedAt: Date(), appName: appName)
        let codec: AVVideoCodecType = settings.recording.videoCodec == .hevc ? .hevc : .h264
        // Errors here (mkdir, recorder.start) are intentionally left uncaught:
        // all three callers already log + notify exactly once in their own
        // do/catch around `try await beginRecording(...)`. A local catch here
        // would double the user-facing "Recording failed" notification.
        try await recorder.start(filter: filter, dimensions: dimensions,
                                 capturesAudio: settings.recording.systemAudio,
                                 codec: codec, outputURL: url) { [weak self] result in
            self?.onStateChange(false)
            switch result {
            case .success(let finishedURL):
                // `deliver` (CaptureCoordinator.deliverRecording) logs the
                // saved file path — don't duplicate that line here.
                self?.deliver(finishedURL, appName)
            case .failure(let error):
                AppLog.log("Recording failed: \(error)")
                self?.effects.notify(title: "Recording failed",
                                     body: String(describing: error), fileURL: nil)
            }
        }
        onStateChange(true)
    }
}
