import Foundation
import LumeshotCore
import LumeshotUpload

struct UploadService {
    private let http: HTTPClient
    private let credentials: CredentialStore
    /// Where a trust-on-first-use SSH host key gets pinned. Optional so tests
    /// and non-app callers can skip persistence entirely.
    private let settingsStore: SettingsStore?
    private let activity: UploadActivity?

    init(http: HTTPClient = URLSessionHTTPClient(), credentials: CredentialStore,
        settingsStore: SettingsStore? = nil, activity: UploadActivity? = nil) {
        self.http = http
        self.credentials = credentials
        self.settingsStore = settingsStore
        self.activity = activity
    }

    static func filePart(pngData: Data, filename: String) -> FilePart {
        FilePart(fieldName: "file", filename: filename, mimeType: "image/png", data: pngData)
    }

    static func filePart(data: Data, filename: String, mime: String) -> FilePart {
        FilePart(fieldName: "file", filename: filename, mimeType: mime, data: data)
    }

    func uploader(for destination: UploadDestination) throws -> Uploader {
        switch destination.kind {
        case .imgur:
            let clientID = destination.imgurClientID ?? ""
            guard !clientID.isEmpty else {
                throw UploadError.missingCredential("Imgur client ID not set")
            }
            return ImgurUploader(clientID: clientID, http: http)

        case .picsur:
            guard let cfg = destination.picsurConfig else {
                throw UploadError.unsupported("Destination has no Picsur config")
            }
            guard cfg.isValid else {
                throw UploadError.unsupported("Picsur host is not a valid http(s) URL: \(cfg.host)")
            }
            let secret = try PicsurCredentials.load(id: destination.id, from: credentials)
            return PicsurUploader(config: cfg, secret: secret, http: http)

        case .customUploader:
            guard let config = destination.customUploader else {
                throw UploadError.unsupported("Destination has no custom-uploader config")
            }
            // Re-hydrate every stripped secret (headers/arguments/parameters/data)
            // from the Keychain immediately before building the request.
            let injected = try SecretVault.inject(config, id: destination.id, from: credentials)
            return CustomUploaderClient(config: injected, http: http)

        case .s3:
            guard let config = destination.s3Config else {
                throw UploadError.unsupported("Destination has no S3 config")
            }
            let creds = try S3Credentials.load(id: destination.id, from: credentials)
            return S3Uploader(config: config, credentials: creds, http: http)

        case .ftp:
            guard let cfg = destination.ftpConfig else {
                throw UploadError.unsupported("Destination has no FTP config")
            }
            let secret = try FTPCredentials.load(id: destination.id, from: credentials)
            return FTPUploader(config: cfg, secret: secret)

        case .sftp:
            guard let cfg = destination.sftpConfig else {
                throw UploadError.unsupported("Destination has no SFTP config")
            }
            let secret = try SFTPCredentials.load(id: destination.id, from: credentials)
            return SFTPUploader(config: cfg, secret: secret,
                                rememberHostKey: hostKeyPinner(for: destination.id,
                                                               host: cfg.host, port: cfg.port))
        }
    }

    /// Persists a first-seen SSH host key against the destination, so every
    /// later connection is checked against it instead of trusting anything.
    /// Re-reads settings at call time because the pin arrives mid-upload, well
    /// after any snapshot we might have taken.
    ///
    /// `host` and `port` are the endpoint that actually presented the key. They
    /// are checked again at write time because the destination can be edited to
    /// point somewhere else while the upload is still connecting: the id alone
    /// would then staple this server's fingerprint onto a different one, and
    /// every later connection there would fail as a host-key mismatch.
    private func hostKeyPinner(for destinationID: String, host: String,
                               port: Int) -> @Sendable (String) -> Void {
        guard let settingsStore else { return { _ in } }
        return { fingerprint in
            // One transaction, because this runs on a NIO event-loop thread while
            // the main actor may be saving a settings edit of its own. Loading and
            // saving separately let the two interleave and drop one of the writes.
            do {
                var pinned = false
                try settingsStore.mutate { settings in
                    guard let index = settings.upload.destinations
                        .firstIndex(where: { $0.id == destinationID }),
                          let current = settings.upload.destinations[index].sftpConfig,
                          current.host == host, current.port == port,
                          (current.knownHostKey ?? "").isEmpty
                    else { return }
                    settings.upload.destinations[index].sftpConfig?.knownHostKey = fingerprint
                    pinned = true
                }
                if pinned {
                    AppLog.log("SFTP: pinned host key for \(destinationID): \(fingerprint)")
                }
            } catch {
                // Not fatal: the upload proceeds, we simply re-learn next time.
                AppLog.log("SFTP: could not pin host key for \(destinationID): \(error)")
            }
        }
    }

    /// Resolves the uploader for `destination` and uploads `data`. Generalizes
    /// the PNG-only `filePart(pngData:filename:)` path so recordings (mp4) and
    /// derived GIFs can reuse the same upload plumbing as stills.
    func upload(data: Data, filename: String, mime: String,
               destination: UploadDestination) async throws -> UploadResult {
        try await upload(part: Self.filePart(data: data, filename: filename, mime: mime),
                         destination: destination)
    }

    /// File-backed entry point: the payload stays on disk, so a long recording
    /// is never materialized just to be uploaded.
    func upload(part: FilePart, destination: UploadDestination, sourcePath: String? = nil,
                historyEntryID: String? = nil) async throws -> UploadResult {
        let filePath: String?
        if case .file(let url, _) = part.source { filePath = url.path } else { filePath = sourcePath }
        let operation = await activity?.begin(filename: part.filename, destination: destination.name,
                                              filePath: filePath, historyEntryID: historyEntryID)
        do {
            let result = try await uploader(for: destination).upload(part)
            if let operation { await activity?.finish(operation, url: result.url) }
            return result
        } catch {
            // Every upload — Test sheet, still capture, recording — funnels through here,
            // so this is the one place that sees the raw error. What the user is shown
            // is UploadFeedback's friendly text, and for `.transport` that is
            // "Couldn't complete the connection", which discards the actual reason. A
            // failing SFTP uploader was undiagnosable for exactly that. `diagnostic`
            // keeps that reason while leaving out response bodies, which can echo a
            // credential straight into the log file.
            AppLog.log("Upload failed via \(destination.name) (\(destination.kind.rawValue)): "
                       + UploadFeedback.diagnostic(for: error))
            if let operation { await activity?.finish(operation, error: UploadFeedback.message(for: error)) }
            throw error
        }
    }
}
