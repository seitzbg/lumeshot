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
    /// The full lifecycle, not just the endpoints. `starting` and `stopping`
    /// exist so every transition happens *synchronously before* an await:
    /// @MainActor gives mutual exclusion only between suspension points, so a
    /// guard on a variable mutated after an await is no guard at all.
    public enum State: Equatable { case idle, starting, recording, stopping }
    public private(set) var state: State = .idle

    /// True from the moment a start is claimed until the session is fully torn
    /// down. Callers must gate on this, not on `state == .recording`.
    public var isBusy: Bool { state != .idle }

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var shim: RecordingDelegateShim?
    private var outputURL: URL?
    private var onFinish: ((Result<URL, RecordingError>) -> Void)?
    private var didDeliver = false   // fire onFinish exactly once per session
    /// Incremented per session so a late delegate callback from a previous
    /// stream can be recognized and dropped instead of being attributed to the
    /// current one.
    private var sessionID: UInt64 = 0

    public init() {}

    /// Start recording `filter` to `url`. `onFinish` is invoked once on MainActor when the file is
    /// finalized (success) or the session fails (failure). Throws synchronously only if start fails.
    public func start(filter: SCContentFilter,
                      dimensions: RecordingDimensions,
                      capturesAudio: Bool,
                      codec: AVVideoCodecType,
                      outputURL url: URL,
                      onFinish: @escaping (Result<URL, RecordingError>) -> Void) async throws {
        let session = try beginSession()

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
            Task { @MainActor in self?.handle(event, session: session) }
        }
        let output = SCRecordingOutput(configuration: recConfig, delegate: shim)
        let stream = SCStream(filter: filter, configuration: config, delegate: shim)
        do {
            try stream.addRecordingOutput(output)   // VERIFY on Mac: if startCapture requires a stream output, add a no-op SCStreamOutput on a bg queue.
        } catch {
            reset()   // we already claimed .starting; release it
            throw error
        }

        self.stream = stream
        self.recordingOutput = output
        self.shim = shim
        self.outputURL = url
        self.onFinish = onFinish
        self.didDeliver = false

        do {
            try await stream.startCapture()
        } catch {
            // Only tear down if this session still owns the recorder.
            if sessionID == session { reset() }
            throw RecordingError.startFailed(error.localizedDescription)
        }
        guard sessionID == session else { return }   // superseded while suspended
        state = .recording
    }

    /// Synchronously claim the recorder for a new session. Called before any
    /// await in `start`, so a second start during the SCK handshake is rejected
    /// rather than silently overwriting the first session's stream and callback.
    private func beginSession() throws -> UInt64 {
        guard state == .idle else { throw RecordingError.alreadyRecording }
        state = .starting
        sessionID &+= 1
        didDeliver = false
        return sessionID
    }

    /// Stop; the file is delivered via the delegate `finished` event (do NOT deliver here).
    public func stop() async {
        // Claim the stop synchronously. Without a `.stopping` state a second
        // stop passed the guard while the first was suspended, called
        // stopCapture() on an already-stopped stream, and turned the resulting
        // throw into a spurious "Recording failed" that raced — and could beat —
        // the genuine finished event.
        guard state == .recording, let stream else { return }
        state = .stopping
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
        self.sessionID &+= 1
        state = .recording
    }

    /// Test-only: the real synchronous claim from `start()`, without an
    /// SCContentFilter (which needs the Screen Recording TCC grant). Lets CI
    /// exercise the exact window a second start would race into.
    @discardableResult
    func _beginSessionForTesting() throws -> UInt64 { try beginSession() }

    /// Test-only: the real synchronous claim from `stop()`.
    func _beginStopForTesting() -> Bool {
        guard state == .recording else { return false }
        state = .stopping
        return true
    }

    func _currentSessionForTesting() -> UInt64 { sessionID }

    func handle(_ event: RecordingEvent, session: UInt64) {
        // A stream from a superseded session can still be delivering callbacks.
        guard session == sessionID else { return }
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
