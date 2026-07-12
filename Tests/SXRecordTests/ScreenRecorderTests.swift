import Foundation
import Testing
@testable import SXRecord

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
        r.handle(.finished)
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
        r.handle(.failed("stream stopped"))
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
        r.handle(.started)
        #expect(r.state == .recording)
        #expect(deliveries == 0)
    }

    @Test func deliversOnlyOncePerSession() {
        let r = ScreenRecorder()
        var deliveries = 0
        r._beginForTesting(outputURL: URL(fileURLWithPath: "/tmp/rec.mp4")) { _ in deliveries += 1 }
        r.handle(.finished)
        r.handle(.failed("late error after finish"))   // must be swallowed — already delivered
        #expect(deliveries == 1)
        #expect(r.state == .idle)
    }
}

import CoreGraphics
// @preconcurrency: see SXCapture/DisplayCapture.swift for why.
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
