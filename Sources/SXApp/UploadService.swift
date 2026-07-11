import Foundation
import SXCore
import SXUpload

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
        }
    }
}
