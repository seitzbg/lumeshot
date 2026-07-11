import Foundation
import SXCore
import SXUpload

struct UploadService {
    static let secretSentinel = "$keychain$"
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
            guard var config = destination.customUploader else {
                throw UploadError.unsupported("Destination has no custom-uploader config")
            }
            config.headers = try injectSecrets(config.headers, destinationID: destination.id)
            config.arguments = try injectSecrets(config.arguments, destinationID: destination.id)
            return CustomUploaderClient(config: config, http: http)
        }
    }

    /// Replace any value equal to the sentinel with the secret stored under
    /// "<destinationID>/<key>"; throw if the secret is missing.
    private func injectSecrets(_ dict: [String: String],
                               destinationID: String) throws -> [String: String] {
        var result = dict
        for (key, value) in dict where value == Self.secretSentinel {
            let account = "\(destinationID)/\(key)"
            guard let secret = try credentials.secret(for: account) else {
                throw UploadError.missingCredential(account)
            }
            result[key] = secret
        }
        return result
    }
}
