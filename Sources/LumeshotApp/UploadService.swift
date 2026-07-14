import Foundation
import LumeshotCore
import LumeshotUpload

struct UploadService {
    private let http: HTTPClient
    private let credentials: CredentialStore

    init(http: HTTPClient = URLSessionHTTPClient(), credentials: CredentialStore) {
        self.http = http
        self.credentials = credentials
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
            return SFTPUploader(config: cfg, secret: secret)
        }
    }

    /// Resolves the uploader for `destination` and uploads `data`. Generalizes
    /// the PNG-only `filePart(pngData:filename:)` path so recordings (mp4) and
    /// derived GIFs can reuse the same upload plumbing as stills.
    func upload(data: Data, filename: String, mime: String,
               destination: UploadDestination) async throws -> UploadResult {
        let uploader = try uploader(for: destination)
        let file = Self.filePart(data: data, filename: filename, mime: mime)
        return try await uploader.upload(file)
    }
}
