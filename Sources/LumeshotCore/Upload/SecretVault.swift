import Foundation

/// Single source of truth for moving `.sxcu` secrets into a `CredentialStore`
/// on import and back out at upload time, so the strip side and the inject side
/// can never drift. Covers ALL four secret-bearing surfaces of a custom
/// uploader — headers, arguments, query parameters, and the raw JSON `data`
/// body template — so no API key or token is left in `settings.json`.
///
/// Keychain accounts are namespaced by surface (`<id>/header/<key>` etc.) so a
/// header and an argument that share a name can't overwrite each other.
public enum SecretVault {
    public static let sentinel = "$keychain$"

    /// Heuristic for map keys that typically carry secrets. Errs toward
    /// stripping: a false positive only stores a non-secret in the Keychain
    /// (harmless, round-trips), whereas a false negative would leak a secret.
    public static func isSecretKey(_ key: String) -> Bool {
        let k = key.lowercased()
        return ["authorization", "auth", "token", "apikey", "api-key", "api_key",
                "secret", "password", "pwd", "cookie", "bearer", "key"]
            .contains { k.contains($0) }
    }

    /// Return a copy of `config` with every secret-looking value moved into
    /// `credentials` and replaced by the sentinel — safe to persist.
    public static func strip(_ config: CustomUploaderConfig, id: String,
                             into credentials: CredentialStore) throws -> CustomUploaderConfig {
        var out = config
        out.headers = try stripMap(config.headers, id: id, surface: "header", into: credentials)
        out.arguments = try stripMap(config.arguments, id: id, surface: "arg", into: credentials)
        out.parameters = try stripMap(config.parameters, id: id, surface: "param", into: credentials)
        if let data = config.data, !data.isEmpty {
            // A JSON body template is freeform and may embed secrets we can't
            // key-detect, so store it wholesale rather than risk leaking one.
            try credentials.setSecret(data, for: account(id: id, surface: "data", key: "body"))
            out.data = sentinel
        }
        return out
    }

    /// Inverse of `strip`: replace sentinels with the stored secret; throw if missing.
    public static func inject(_ config: CustomUploaderConfig, id: String,
                              from credentials: CredentialStore) throws -> CustomUploaderConfig {
        var out = config
        out.headers = try injectMap(config.headers, id: id, surface: "header", from: credentials)
        out.arguments = try injectMap(config.arguments, id: id, surface: "arg", from: credentials)
        out.parameters = try injectMap(config.parameters, id: id, surface: "param", from: credentials)
        if config.data == sentinel {
            let acct = account(id: id, surface: "data", key: "body")
            guard let secret = try credentials.secret(for: acct) else {
                throw UploadError.missingCredential(acct)
            }
            out.data = secret
        }
        return out
    }

    /// Delete every Keychain account this stripped config's secrets occupy.
    /// Call on destination removal so no orphaned secrets linger.
    public static func purge(_ config: CustomUploaderConfig, id: String,
                             from credentials: CredentialStore) throws {
        for (key, value) in config.headers where value == sentinel {
            try credentials.deleteSecret(for: account(id: id, surface: "header", key: key))
        }
        for (key, value) in config.arguments where value == sentinel {
            try credentials.deleteSecret(for: account(id: id, surface: "arg", key: key))
        }
        for (key, value) in config.parameters where value == sentinel {
            try credentials.deleteSecret(for: account(id: id, surface: "param", key: key))
        }
        if config.data == sentinel {
            try credentials.deleteSecret(for: account(id: id, surface: "data", key: "body"))
        }
    }

    private static func account(id: String, surface: String, key: String) -> String {
        "\(id)/\(surface)/\(key)"
    }

    private static func stripMap(_ dict: [String: String], id: String, surface: String,
                                 into credentials: CredentialStore) throws -> [String: String] {
        var out = dict
        for (key, value) in dict where isSecretKey(key) && !value.isEmpty {
            try credentials.setSecret(value, for: account(id: id, surface: surface, key: key))
            out[key] = sentinel
        }
        return out
    }

    private static func injectMap(_ dict: [String: String], id: String, surface: String,
                                  from credentials: CredentialStore) throws -> [String: String] {
        var out = dict
        for (key, value) in dict where value == sentinel {
            let acct = account(id: id, surface: surface, key: key)
            guard let secret = try credentials.secret(for: acct) else {
                throw UploadError.missingCredential(acct)
            }
            out[key] = secret
        }
        return out
    }
}
