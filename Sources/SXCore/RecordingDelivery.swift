import Foundation

/// The URL(s) a successful upload produced, decoupled from SXUpload's
/// `UploadResult` so this SXCore-level delivery core takes no SXUpload dependency.
public struct DeliveredUpload: Sendable {
    public let url: String
    public let deletionURL: String?
    public init(url: String, deletionURL: String?) {
        self.url = url
        self.deletionURL = deletionURL
    }
}

/// Library-level delivery core for an already-on-disk artifact (a recording's
/// mp4, or a derived gif). Lives in SXCore — NOT SXApp — because SXApp is an
/// executable target with top-level code (`main.swift`) that a test target
/// cannot `@testable import`; hoisting the ordering here makes it unit-testable
/// in SXCoreTests with a `PipelineEffects` mock, a temp-file `HistoryStore`,
/// and an injected `upload` closure.
public enum RecordingDelivery {
    /// Records the history row FIRST (the file is already on disk = local-first
    /// satisfied), then — only when `shouldUpload` — reads the file and awaits
    /// `upload`, finalizing the row with the result. On upload failure the row
    /// REMAINS with `uploadFailed = true` and the file is never touched.
    /// `async` (awaits the upload inline) so callers/tests can await completion
    /// deterministically instead of racing a detached Task.
    @MainActor
    public static func deliver(
        fileURL: URL,
        capturedAt: Date,
        destinationName: String?,
        shouldUpload: Bool,
        showNotification: Bool,
        mime: String,
        history: HistoryStore?,
        effects: any PipelineEffects,
        upload: @escaping (Data, String, String) async throws -> DeliveredUpload
    ) async {
        let entryID = UUID().uuidString
        // History row first: the artifact is already on disk, so recording the
        // row before any upload preserves local-first. Best-effort — SXCore has
        // no AppLog and the durable artifact is the file, not the row, so a
        // store failure never blocks or discards the on-disk recording.
        if let history {
            let entry = HistoryEntry(id: entryID, capturedAt: capturedAt,
                                     filePath: fileURL.path, url: nil, deletionURL: nil,
                                     destinationName: shouldUpload ? destinationName : nil,
                                     uploadFailed: false)
            try? history.insert(entry)
        }

        guard shouldUpload else {
            if showNotification {
                effects.notify(title: "Recording saved", body: fileURL.lastPathComponent, fileURL: fileURL)
            }
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let result = try await upload(data, fileURL.lastPathComponent, mime)
            effects.copyTextToClipboard(result.url)
            effects.notifyURL(title: "Uploaded", body: result.url, url: result.url)
            try? history?.setURL(id: entryID, url: result.url, deletionURL: result.deletionURL, failed: false)
        } catch {
            // Fail-loud: surface the failure; the row + file remain (local-first).
            effects.notify(title: "Upload failed", body: "\(error). Local file kept.", fileURL: fileURL)
            try? history?.setURL(id: entryID, url: nil, deletionURL: nil, failed: true)
        }
    }
}

extension RecordingDelivery {
    /// Resolves a recording's destination path: the capture-save directory +
    /// the same `NameParser` template used for stills, with a `.mp4` extension
    /// and numeric-suffix collision handling. Pure and static — unit-testable
    /// without SCK or real disk I/O (`fileExists` is injectable; production
    /// calls default to the real filesystem). Unlike
    /// `AfterCapturePipeline.resolveCollisions`, this always appends a plain
    /// `_n` suffix on collision — it does not re-render `%i` tokens in the
    /// filename template.
    public static func outputURL(
        settings: AppSettings, capturedAt: Date, appName: String?,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let dir = URL(fileURLWithPath: (settings.captureSavePath as NSString).expandingTildeInPath)
        let ctx = NameContext(date: capturedAt, width: nil, height: nil, processName: appName, increment: 0)
        let base = NameParser.sanitize(NameParser.render(settings.filenameTemplate, context: ctx))
        var url = dir.appendingPathComponent(base + ".mp4")
        var n = 1
        while fileExists(url) {
            url = dir.appendingPathComponent("\(base)_\(n).mp4")
            n += 1
        }
        return url
    }

    /// The source video's sibling `.gif` path (`<name>.gif` next to it; `_1`,
    /// `_2`, … on collision). Pure and injectable — `fileExists` defaults to the
    /// real filesystem.
    public static func gifOutputURL(
        for sourceURL: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let dir = sourceURL.deletingLastPathComponent()
        let base = sourceURL.deletingPathExtension().lastPathComponent
        var url = dir.appendingPathComponent(base + ".gif")
        var n = 1
        while fileExists(url) {
            url = dir.appendingPathComponent("\(base)_\(n).gif")
            n += 1
        }
        return url
    }
}
