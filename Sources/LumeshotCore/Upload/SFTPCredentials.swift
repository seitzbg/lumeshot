import Foundation

/// Loaded SFTP secret material from the Keychain — password and/or private key.
public struct SFTPSecret: Equatable, Sendable {
    public var password: String?
    public var privateKeyPEM: String?
    public var passphrase: String?

    public init(password: String? = nil, privateKeyPEM: String? = nil, passphrase: String? = nil) {
        self.password = password
        self.privateKeyPEM = privateKeyPEM
        self.passphrase = passphrase
    }
}

/// Moves SFTP secret material in/out of a `CredentialStore`, namespaced under
/// `<id>/sftp/*`, so nothing sensitive is written to settings.json.
public enum SFTPCredentials {
    private static func account(_ id: String, _ key: String) -> String { "\(id)/sftp/\(key)" }

    /// Stores only the non-nil fields — a key-only destination never writes a
    /// "password" account, and vice versa. All-or-nothing: any internal write
    /// failure purges everything written for `id` so far, so a partial Keychain
    /// write never lingers as an orphan.
    public static func store(password: String?, privateKeyPEM: String?, passphrase: String?,
                             id: String, into c: CredentialStore) throws {
        do {
            if let password { try c.setSecret(password, for: account(id, "password")) }
            if let privateKeyPEM { try c.setSecret(privateKeyPEM, for: account(id, "privateKey")) }
            if let passphrase { try c.setSecret(passphrase, for: account(id, "passphrase")) }
        } catch {
            try? purge(id: id, from: c)   // purge is idempotent (deleteSecret ignores not-found)
            throw error
        }
    }

    /// Loads whatever is present; does NOT throw when everything is absent — the
    /// transport (`CitadelSFTPTransport`) is what enforces "at least one of
    /// password/private key" at upload time via `UploadError.missingCredential`.
    public static func load(id: String, from c: CredentialStore) throws -> SFTPSecret {
        SFTPSecret(password: try c.secret(for: account(id, "password")),
                  privateKeyPEM: try c.secret(for: account(id, "privateKey")),
                  passphrase: try c.secret(for: account(id, "passphrase")))
    }

    public static func purge(id: String, from c: CredentialStore) throws {
        try c.deleteSecret(for: account(id, "password"))
        try c.deleteSecret(for: account(id, "privateKey"))
        try c.deleteSecret(for: account(id, "passphrase"))
    }
}
