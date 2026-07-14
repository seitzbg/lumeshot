@preconcurrency import ScreenCaptureKit
import AVFoundation
import CoreGraphics

/// Sendable event surfaced from background delegate callbacks.
enum RecordingEvent: Sendable {
    case started
    case finished
    case failed(String)
}

/// nonisolated delegate shim: no mutable state, only an immutable @Sendable sink. Safe to receive
/// callbacks on SCK's background queue. Retained by ScreenRecorder (SCK delegates are weak).
final class RecordingDelegateShim: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    private let sink: @Sendable (RecordingEvent) -> Void
    init(sink: @escaping @Sendable (RecordingEvent) -> Void) { self.sink = sink }

    // SCRecordingOutputDelegate
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) { sink(.started) }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { sink(.failed(error.localizedDescription)) }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { sink(.finished) }

    // SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) { sink(.failed(error.localizedDescription)) }
}

@MainActor
public final class ScreenRecorder {
    public enum State: Equatable { case idle, recording }
    public private(set) var state: State = .idle

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var shim: RecordingDelegateShim?
    private var outputURL: URL?
    private var onFinish: ((Result<URL, RecordingError>) -> Void)?
    private var didDeliver = false   // fire onFinish exactly once per session

    public init() {}

    /// Start recording `filter` to `url`. `onFinish` is invoked once on MainActor when the file is
    /// finalized (success) or the session fails (failure). Throws synchronously only if start fails.
    public func start(filter: SCContentFilter,
                      dimensions: RecordingDimensions,
                      capturesAudio: Bool,
                      codec: AVVideoCodecType,
                      outputURL url: URL,
                      onFinish: @escaping (Result<URL, RecordingError>) -> Void) async throws {
        guard state == .idle else { throw RecordingError.alreadyRecording }

        let config = SCStreamConfiguration()
        config.width = dimensions.width
        config.height = dimensions.height
        if let sr = dimensions.sourceRect { config.sourceRect = sr }
        config.showsCursor = true
        config.capturesAudio = capturesAudio
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 6

        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = url
        recConfig.outputFileType = .mp4
        recConfig.videoCodecType = codec

        let shim = RecordingDelegateShim { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        let output = SCRecordingOutput(configuration: recConfig, delegate: shim)
        let stream = SCStream(filter: filter, configuration: config, delegate: shim)
        try stream.addRecordingOutput(output)   // VERIFY on Mac: if startCapture requires a stream output, add a no-op SCStreamOutput on a bg queue.

        self.stream = stream
        self.recordingOutput = output
        self.shim = shim
        self.outputURL = url
        self.onFinish = onFinish
        self.didDeliver = false

        do {
            try await stream.startCapture()
        } catch {
            reset()
            throw RecordingError.startFailed(error.localizedDescription)
        }
        state = .recording
    }

    /// Stop; the file is delivered via the delegate `finished` event (do NOT deliver here).
    public func stop() async {
        guard state == .recording, let stream else { return }
        do { try await stream.stopCapture() }
        catch { deliver(.failure(.recordingFailed(error.localizedDescription))); return }
        // success delivered by recordingOutputDidFinishRecording
    }

    /// Test-only seam: puts the recorder into `.recording` with a synthetic
    /// completion, bypassing SCStream/SCRecordingOutput entirely, so the pure
    /// state machine (fire-once `deliver`, `handle` event -> outcome mapping,
    /// reset-to-idle) is unit-testable without live ScreenCaptureKit access or
    /// the Screen Recording TCC grant.
    func _beginForTesting(outputURL: URL, onFinish: @escaping (Result<URL, RecordingError>) -> Void) {
        self.outputURL = outputURL
        self.onFinish = onFinish
        self.didDeliver = false
        state = .recording
    }

    /// Test-only: mirrors start()'s re-entrancy guard without constructing an SCContentFilter
    /// (which needs the Screen Recording TCC grant). Lets CI verify the guard fires.
    func _assertIdleForTesting() throws {
        guard state == .idle else { throw RecordingError.alreadyRecording }
    }

    func handle(_ event: RecordingEvent) {
        switch event {
        case .started: break
        case .finished:
            if let url = outputURL { deliver(.success(url)) } else { deliver(.failure(.recordingFailed("no output url"))) }
        case .failed(let msg):
            deliver(.failure(.recordingFailed(msg)))
        }
    }

    private func deliver(_ result: Result<URL, RecordingError>) {
        guard !didDeliver else { return }
        didDeliver = true
        let cb = onFinish
        reset()
        cb?(result)
    }

    private func reset() {
        stream = nil; recordingOutput = nil; shim = nil; outputURL = nil; onFinish = nil
        state = .idle
    }
}
