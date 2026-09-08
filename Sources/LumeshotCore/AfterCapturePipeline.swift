import Foundation

@MainActor
public protocol PipelineEffects {
    /// Pasteboard ownership generation, used to detect copies during an upload.
    /// Checking this and writing are separate operations, not an atomic transaction.
    var clipboardChangeCount: Int { get }
    func fileExists(at url: URL) -> Bool
    func writeFile(_ data: Data, to url: URL) throws
    func copyImageToClipboard(_ pngData: Data)
    func notify(title: String, body: String, fileURL: URL?)
    func copyTextToClipboard(_ text: String)
    func notifyURL(title: String, body: String, url: String)
    /// Diagnostic logging. LumeshotCore has no AppLog of its own, so this is how
    /// code here reaches the app's log file. Defaulted to a no-op so test doubles
    /// need not implement it.
    func log(_ message: String)
}

public extension PipelineEffects {
    func log(_ message: String) {}
}

/// Whether the disk write is governed by the user's automatic-capture
/// preference or demanded by an explicit command.
///
/// `saveToDisk` is an *after-capture automation* setting. Routing explicit
/// editor actions through it made the editor's "Save to disk" button write
/// nothing whenever that automation was switched off.
public enum SavePolicy: Equatable, Sendable {
    /// Honor `settings.saveToDisk` — the automatic path after a capture.
    case followSettings
    /// Always write, whatever the setting says — the user asked for a file.
    case require
}

public struct PipelineResult: Equatable, Sendable {
    public let savedURL: URL?
    public let copiedToClipboard: Bool
    /// The name an upload of this capture should use. Always present, whether or
    /// not a file was written, so no caller has to invent one.
    public let uploadFilename: String
}

@MainActor
public struct AfterCapturePipeline {
    private let settings: AppSettings
    private let effects: any PipelineEffects

    public init(settings: AppSettings, effects: any PipelineEffects) {
        self.settings = settings
        self.effects = effects
    }

    public func process(_ artifact: CaptureArtifact,
                        savePolicy: SavePolicy = .followSettings) throws -> PipelineResult {
        var savedURL: URL?

        if settings.saveToDisk || savePolicy == .require {
            let dir = URL(fileURLWithPath: (settings.captureSavePath as NSString).expandingTildeInPath)
            let url = resolveCollisions(in: dir, artifact: artifact)
            try effects.writeFile(artifact.pngData, to: url)   // disk first: local-first invariant
            savedURL = url
        }
        // Keep the image available until a successful upload replaces it with its URL.
        effects.copyImageToClipboard(artifact.pngData)
        if settings.showNotification {
            let what = savedURL?.lastPathComponent ?? "\(artifact.width)×\(artifact.height) capture"
            effects.notify(title: "Capture complete", body: what, fileURL: savedURL)
        }
        return PipelineResult(savedURL: savedURL, copiedToClipboard: true,
                             uploadFilename: savedURL?.lastPathComponent
                                 ?? unsavedUploadName(artifact: artifact))
    }

    /// The upload name for a capture that was never written to disk.
    ///
    /// Uploads used to fall back to the constant "capture.png" whenever "Save a
    /// copy" was off. Destinations that key off the filename — the S3 object
    /// key, the SFTP/FTP remote path — then wrote every capture over the last
    /// one, and with no local copy there was nothing left to recover from.
    ///
    /// The rendered template alone does not fix it: its finest unit is the
    /// second, so two captures in the same second still collide, and a template
    /// without a time token collides always. The random suffix is what actually
    /// carries the uniqueness, across sessions as well as within one.
    private func unsavedUploadName(artifact: CaptureArtifact) -> String {
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        return "\(renderName(artifact: artifact, increment: 0))-\(suffix).png"
    }

    private func renderName(artifact: CaptureArtifact, increment: Int) -> String {
        let ctx = NameContext(date: artifact.capturedAt, width: artifact.width,
                              height: artifact.height, processName: artifact.appName,
                              increment: increment)
        return NameParser.sanitize(NameParser.render(settings.filenameTemplate, context: ctx))
    }

    private func resolveCollisions(in dir: URL, artifact: CaptureArtifact) -> URL {
        func render(increment: Int) -> String { renderName(artifact: artifact, increment: increment) }
        let usesIncrement = settings.filenameTemplate.contains("%i")
        let base = render(increment: 0)
        var url = dir.appendingPathComponent(base + ".png")
        var n = 1
        while effects.fileExists(at: url) {
            let name = usesIncrement ? render(increment: n) : "\(base)_\(n)"
            url = dir.appendingPathComponent(name + ".png")
            n += 1
        }
        return url
    }
}
