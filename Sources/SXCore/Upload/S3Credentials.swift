import Foundation

/// Moves S3 secret material in/out of a `CredentialStore`, namespaced under
/// `<id>/s3/*`, so nothing sensitive is written to settings.json.
public enum S3Credentials {
    private static func account(_ id: String, _ key: String) -> String { "\(id)/s3/\(key)" }

    public static func store(accessKeyID: String, secretAccessKey: String,
                             id: String, into credentials: CredentialStore) throws {
        do {
            try credentials.setSecret(accessKeyID, for: account(id, "accessKeyID"))
            try credentials.setSecret(secretAccessKey, for: account(id, "secretAccessKey"))
        } catch {
            try? purge(id: id, from: credentials)   // purge is idempotent (deleteSecret ignores not-found)
            throw error
        }
    }

    public static func load(id: String, from credentials: CredentialStore) throws -> SigV4Credentials {
        guard let ak = try credentials.secret(for: account(id, "accessKeyID")) else {
            throw UploadError.missingCredential(account(id, "accessKeyID"))
        }
        guard let sk = try credentials.secret(for: account(id, "secretAccessKey")) else {
            throw UploadError.missingCredential(account(id, "secretAccessKey"))
        }
        return SigV4Credentials(accessKeyID: ak, secretAccessKey: sk)
    }

    public static func purge(id: String, from credentials: CredentialStore) throws {
        try credentials.deleteSecret(for: account(id, "accessKeyID"))
        try credentials.deleteSecret(for: account(id, "secretAccessKey"))
    }
}
