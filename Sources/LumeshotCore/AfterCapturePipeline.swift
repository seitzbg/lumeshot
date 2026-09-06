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
        return PipelineResult(savedURL: savedURL, copiedToClipboard: true)
    }

    private func resolveCollisions(in dir: URL, artifact: CaptureArtifact) -> URL {
        func render(increment: Int) -> String {
            let ctx = NameContext(date: artifact.capturedAt, width: artifact.width,
                                  height: artifact.height, processName: artifact.appName,
                                  increment: increment)
            return NameParser.sanitize(NameParser.render(settings.filenameTemplate, context: ctx))
        }
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
