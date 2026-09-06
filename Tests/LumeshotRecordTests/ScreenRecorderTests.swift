import Foundation
import Testing
@testable import LumeshotRecord

@MainActor @Suite struct ScreenRecorderStateMachineTests {
    @Test func startsIdle() {
        let r = ScreenRecorder()
        #expect(r.state == .idle)
    }

    @Test func finishedEventDeliversSuccessAndResetsToIdle() {
        let r = ScreenRecorder()
        let url = URL(fileURLWithPath: "/tmp/rec.mp4")
        var delivered: Result<URL, RecordingError>?
        r._beginForTesting(outputURL: url) { delivered = $0 }
        r.handle(.finished, session: r._currentSessionForTesting())
        #expect(r.state == .idle)
        switch delivered {
        case .success(let deliveredURL): #expect(deliveredURL == url)
        default: Issue.record("expected .success")
        }
    }

    @Test func failedEventDeliversFailureAndResetsToIdle() {
        let r = ScreenRecorder()
        var delivered: Result<URL, RecordingError>?
        r._beginForTesting(outputURL: URL(fileURLWithPath: "/tmp/rec.mp4")) { delivered = $0 }
        r.handle(.failed("stream stopped"), session: r._currentSessionForTesting())
        #expect(r.state == .idle)
        switch delivered {
        case .failure(.recordingFailed(let msg)): #expect(msg == "stream stopped")
        default: Issue.record("expected .failure(.recordingFailed)")
        }
    }

    @Test func startedEventDoesNotDeliverOrChangeState() {
        let r = ScreenRecorder()
        var deliveries = 0
        r._beginForTesting(outputURL: URL(fileURLWithPath: "/tmp/rec.mp4")) { _ in deliveries += 1 }
        r.handle(.started, session: r._currentSessionForTesting())
        #expect(r.state == .recording)
        #expect(deliveries == 0)
    }

    @Test func deliversOnlyOncePerSession() {
        let r = ScreenRecorder()
        var deliveries = 0
        r._beginForTesting(outputURL: URL(fileURLWithPath: "/tmp/rec.mp4")) { _ in deliveries += 1 }
        r.handle(.finished, session: r._currentSessionForTesting())
        r.handle(.failed("late error after finish"), session: r._currentSessionForTesting())   // must be swallowed — already delivered
        #expect(deliveries == 1)
        #expect(r.state == .idle)
    }

    @Test func secondStartWhileRecordingThrowsAlreadyRecording() {
        let r = ScreenRecorder()
        r._beginForTesting(outputURL: URL(fileURLWithPath: "/tmp/rec.mp4")) { _ in }
        #expect(throws: RecordingError.alreadyRecording) { try r._beginSessionForTesting() }
    }

    // MARK: - Re-entrancy across suspension points

    /// The regression this whole state machine exists for: a second start that
    /// arrives while the first is suspended in `startCapture()`. `.starting` is
    /// claimed synchronously, so the second claim is rejected instead of
    /// overwriting the first session's stream, output URL and callback.
    @Test func secondStartDuringTheStartingWindowIsRejected() throws {
        let r = ScreenRecorder()
        try r._beginSessionForTesting()          // first start, now suspended at startCapture()
        #expect(r.state == .starting)
        #expect(r.isBusy)
        #expect(throws: RecordingError.alreadyRecording) { try r._beginSessionForTesting() }
    }

    @Test func aStartIsRejectedWhileStopping() {
        let r = ScreenRecorder()
        r._beginForTesting(outputURL: URL(fileURLWithPath: "/tmp/rec.mp4")) { _ in }
        #expect(r._beginStopForTesting())
        #expect(r.state == .stopping)
        #expect(throws: RecordingError.alreadyRecording) { try r._beginSessionForTesting() }
    }

    /// A second stop must not reach `stopCapture()` on an already-stopping
    /// stream: that throw was being converted into a spurious "Recording
    /// failed" that could beat the genuine finished event.
    @Test func secondStopDuringTheStoppingWindowIsIgnored() {
        let r = ScreenRecorder()
        r._beginForTesting(outputURL: URL(fileURLWithPath: "/tmp/rec.mp4")) { _ in }
        #expect(r._beginStopForTesting())
        #expect(!r._beginStopForTesting())
    }

    @Test func isBusyCoversEveryNonIdleState() {
        let r = ScreenRecorder()
        #expect(!r.isBusy)
        r._beginForTesting(outputURL: URL(fileURLWithPath: "/tmp/rec.mp4")) { _ in }
        #expect(r.isBusy)
        _ = r._beginStopForTesting()
        #expect(r.isBusy)
    }

    /// A late callback from a superseded stream must not be attributed to the
    /// session that replaced it.
    @Test func aStaleSessionCallbackIsDropped() {
        let r = ScreenRecorder()
        var deliveries = 0
        r._beginForTesting(outputURL: URL(fileURLWithPath: "/tmp/rec.mp4")) { _ in deliveries += 1 }
        let stale = r._currentSessionForTesting() &- 1
        r.handle(.finished, session: stale)
        #expect(deliveries == 0)
        #expect(r.state == .recording)
        r.handle(.finished, session: r._currentSessionForTesting())
        #expect(deliveries == 1)
    }
}

import CoreGraphics
// @preconcurrency: see LumeshotCapture/DisplayCapture.swift for why.
@preconcurrency import ScreenCaptureKit
import AVFoundation

@MainActor @Suite struct ScreenRecorderLiveTests {
    @Test(.enabled(if: CGPreflightScreenCaptureAccess()))
    func recordsAShortClipToAnMP4File() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            Issue.record("no displays available to record"); return
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let dims = RecordingDimensions.display(pointWidth: 640, pointHeight: 360, scale: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")

        let recorder = ScreenRecorder()
        let outcome = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result<URL, RecordingError>, Error>) in
            Task { @MainActor in
                do {
                    try await recorder.start(filter: filter, dimensions: dims, capturesAudio: false,
                                             codec: .h264, outputURL: url) { result in
                        cont.resume(returning: result)
                    }
                    try await Task.sleep(for: .seconds(1))
                    await recorder.stop()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        switch outcome {
        case .success(let finishedURL):
            #expect(finishedURL == url)
            #expect(FileManager.default.fileExists(atPath: url.path))
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attrs[.size] as? Int ?? 0) > 0)
        case .failure(let error):
            Issue.record("recording failed: \(error)")
        }
        #expect(recorder.state == .idle)
        try? FileManager.default.removeItem(at: url)
    }

    @Test(.enabled(if: CGPreflightScreenCaptureAccess()))
    func startWhileRecordingThrowsAlreadyRecording() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            Issue.record("no displays available to record"); return
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let dims = RecordingDimensions.display(pointWidth: 640, pointHeight: 360, scale: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let recorder = ScreenRecorder()
        try await recorder.start(filter: filter, dimensions: dims, capturesAudio: false,
                                 codec: .h264, outputURL: url) { _ in }
        await #expect(throws: RecordingError.alreadyRecording) {
            try await recorder.start(filter: filter, dimensions: dims, capturesAudio: false,
                                     codec: .h264, outputURL: url) { _ in }
        }
        await recorder.stop()
        try? FileManager.default.removeItem(at: url)
    }
}
