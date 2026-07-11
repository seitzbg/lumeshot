import Foundation
import SXCore

enum SxcuImporter {
    /// Heuristic: header/argument keys that typically carry secrets.
    private static func isSecretKey(_ key: String) -> Bool {
        let k = key.lowercased()
        return k == "authorization" || k.contains("token") || k.contains("apikey")
            || k.contains("api-key") || k.contains("secret") || k.contains("key")
    }

    static func makeDestination(from data: Data, id: String,
                                credentials: CredentialStore) throws -> UploadDestination {
        var config = try CustomUploaderConfig.parse(data)

        func stripSecrets(_ dict: [String: String]) throws -> [String: String] {
            var out = dict
            for (key, value) in dict where isSecretKey(key) && !value.isEmpty {
                try credentials.setSecret(value, for: "\(id)/\(key)")
                out[key] = UploadService.secretSentinel
            }
            return out
        }
        config.headers = try stripSecrets(config.headers)
        config.arguments = try stripSecrets(config.arguments)

        return UploadDestination(id: id, name: config.name ?? "Custom uploader",
                                 kind: .customUploader, customUploader: config,
                                 imgurClientID: nil)
    }
}
