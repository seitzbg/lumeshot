import Foundation
import LumeshotCore

/// Picsur (https://github.com/CaramelFur/Picsur) — a self-hosted image host.
///
/// Picsur's upload API is exactly a ShareX custom uploader, so this synthesizes
/// the same `CustomUploaderConfig` its own generator emits and delegates to the
/// shared engine — the pattern `ImgurUploader` uses. Keeping the template here
/// (rather than asking the user to import a .sxcu) means the API key round-trips
/// through the Keychain and the host is editable without re-importing a file.
public struct PicsurUploader: Uploader {
    private let config: PicsurConfig
    private let apiKey: String
    private let http: HTTPClient

    public init(config: PicsurConfig, secret: PicsurSecret, http: HTTPClient) {
        self.config = config
        self.apiKey = secret.apiKey
        self.http = http
    }

    public func upload(_ file: FilePart) async throws -> UploadResult {
        var uploader = CustomUploaderConfig(requestURL: config.uploadURL)
        uploader.name = "Picsur"
        uploader.headers = ["Authorization": "Api-Key \(apiKey)"]
        uploader.body = .multipartFormData
        uploader.fileFormName = "image"
        // Resolve the bare id/delete key rather than a finished URL: a template
        // like "<host>/i/{json:data.id}.png" still resolves non-empty when Picsur
        // omits the id (an error body), so the engine's emptyURL guard would not
        // fire and a broken "<host>/i/.png" would reach the clipboard. Asking for
        // the id alone makes that guard do the validating, and we compose after.
        uploader.url = "{json:data.id}"
        uploader.deletionURL = "{json:data.delete_key}"

        let raw = try await CustomUploaderClient(config: uploader, http: http).upload(file)
        let id = raw.url
        return UploadResult(url: config.url(id: id),
                            thumbnailURL: config.thumbnailURL(id: id),
                            deletionURL: (raw.deletionURL?.isEmpty ?? true)
                                ? nil : config.deletionURL(id: id, deleteKey: raw.deletionURL!))
    }
}
