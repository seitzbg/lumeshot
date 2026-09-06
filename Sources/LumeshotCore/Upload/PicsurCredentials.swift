import Foundation

/// Loaded Picsur secret material from the Keychain.
public struct PicsurSecret: Equatable, Sendable {
    public var apiKey: String
    public init(apiKey: String) { self.apiKey = apiKey }
}

/// Moves the Picsur API key in/out of a `CredentialStore`, namespaced under
/// `<id>/picsur/*`, so nothing sensitive is written to settings.json.
public enum PicsurCredentials {
    private static func account(_ id: String, _ key: String) -> String { "\(id)/picsur/\(key)" }

    public static func store(apiKey: String, id: String, into c: CredentialStore) throws {
        try c.setSecret(apiKey, for: account(id, "apiKey"))
    }

    public static func load(id: String, from c: CredentialStore) throws -> PicsurSecret {
        guard let apiKey = try c.secret(for: account(id, "apiKey")) else {
            throw UploadError.missingCredential(account(id, "apiKey"))
        }
        return PicsurSecret(apiKey: apiKey)
    }

    public static func purge(id: String, from c: CredentialStore) throws {
        try c.deleteSecret(for: account(id, "apiKey"))
    }
}
