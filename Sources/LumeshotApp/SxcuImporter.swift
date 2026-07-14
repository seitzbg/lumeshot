import Foundation
import LumeshotCore

enum SxcuImporter {
    /// Parse a `.sxcu`, move every secret it carries (across all surfaces) into
    /// the Keychain via `SecretVault`, and return a destination whose persisted
    /// config holds only sentinels — never a raw credential.
    static func makeDestination(from data: Data, id: String,
                                credentials: CredentialStore) throws -> UploadDestination {
        let parsed = try CustomUploaderConfig.parse(data)
        let stripped = try SecretVault.strip(parsed, id: id, into: credentials)
        return UploadDestination(id: id, name: stripped.name ?? "Custom uploader",
                                 kind: .customUploader, customUploader: stripped,
                                 imgurClientID: nil)
    }
}
