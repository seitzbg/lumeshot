import Foundation

/// Loaded FTP secret material from the Keychain.
public struct FTPSecret: Equatable, Sendable {
    public var password: String
    public init(password: String) { self.password = password }
}

/// Moves FTP secret material in/out of a `CredentialStore`, namespaced under
/// `<id>/ftp/*`, so nothing sensitive is written to settings.json.
public enum FTPCredentials {
    private static func account(_ id: String, _ key: String) -> String { "\(id)/ftp/\(key)" }

    public static func store(password: String, id: String, into c: CredentialStore) throws {
        try c.setSecret(password, for: account(id, "password"))
    }

    public static func load(id: String, from c: CredentialStore) throws -> FTPSecret {
        guard let password = try c.secret(for: account(id, "password")) else {
            throw UploadError.missingCredential(account(id, "password"))
        }
        return FTPSecret(password: password)
    }

    public static func purge(id: String, from c: CredentialStore) throws {
        try c.deleteSecret(for: account(id, "password"))
    }
}
