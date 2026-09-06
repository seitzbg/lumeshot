import Foundation

/// Single source of truth for moving `.sxcu` secrets into a `CredentialStore`
/// on import and back out at upload time, so the strip side and the inject side
/// can never drift.
///
/// Two different strategies, because only one of them can be relied on:
///
/// * **Wholesale** for surfaces whose contents are freeform and cannot be
///   key-inspected — the JSON `data` body, and a `RequestURL` carrying a query
///   or user-info. These go to the Keychain in full. A token in a query string
///   (`?api_key=…`) is a common uploader design and was previously persisted
///   verbatim.
/// * **Key-name heuristic** for headers/arguments/parameters, where the map key
///   is a real signal. This is a best-effort net, not a guarantee: a secret
///   under a genuinely innocuous key still slips through.
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
                "secret", "password", "pwd", "cookie", "bearer", "key",
                "session", "sig", "signature", "credential", "private"]
            .contains { k.contains($0) }
    }

    /// Return a copy of `config` with every secret-looking value moved into
    /// `credentials` and replaced by the sentinel — safe to persist.
    ///
    /// All-or-nothing: a write that fails partway deletes everything already
    /// written for `id`, matching the S3/SFTP helpers. Otherwise a half-stripped
    /// import left orphaned Keychain entries no destination pointed at.
    public static func strip(_ config: CustomUploaderConfig, id: String,
                             into credentials: CredentialStore) throws -> CustomUploaderConfig {
        var written: [String] = []
        do {
            var out = config
            out.headers = try stripMap(config.headers, id: id, surface: "header",
                                       into: credentials, written: &written)
            out.arguments = try stripMap(config.arguments, id: id, surface: "arg",
                                         into: credentials, written: &written)
            out.parameters = try stripMap(config.parameters, id: id, surface: "param",
                                          into: credentials, written: &written)
            if Self.urlNeedsProtecting(config.requestURL) {
                // A query string or user-info can carry the whole credential,
                // and neither is key-inspectable in a way we'd trust. Store the
                // URL in full rather than guess which part is sensitive.
                let acct = account(id: id, surface: "url", key: "requestURL")
                try credentials.setSecret(config.requestURL, for: acct)
                written.append(acct)
                out.requestURL = sentinel
            }
            if let data = config.data, !data.isEmpty {
                // A JSON body template is freeform and may embed secrets we can't
                // key-detect, so store it wholesale rather than risk leaking one.
                let acct = account(id: id, surface: "data", key: "body")
                try credentials.setSecret(data, for: acct)
                written.append(acct)
                out.data = sentinel
            }
            return out
        } catch {
            _ = CredentialTransaction.purgeRestorable(written, in: credentials)
            throw error
        }
    }

    /// Every Keychain account this stripped config's secrets occupy.
    public static func accounts(_ config: CustomUploaderConfig, id: String) -> [String] {
        var accounts: [String] = []
        for (key, value) in config.headers where value == sentinel {
            accounts.append(account(id: id, surface: "header", key: key))
        }
        for (key, value) in config.arguments where value == sentinel {
            accounts.append(account(id: id, surface: "arg", key: key))
        }
        for (key, value) in config.parameters where value == sentinel {
            accounts.append(account(id: id, surface: "param", key: key))
        }
        if config.data == sentinel {
            accounts.append(account(id: id, surface: "data", key: "body"))
        }
        if config.requestURL == sentinel {
            accounts.append(account(id: id, surface: "url", key: "requestURL"))
        }
        return accounts
    }

    /// Inverse of `strip`: replace sentinels with the stored secret; throw if missing.
    public static func inject(_ config: CustomUploaderConfig, id: String,
                              from credentials: CredentialStore) throws -> CustomUploaderConfig {
        var out = config
        out.headers = try injectMap(config.headers, id: id, surface: "header", from: credentials)
        out.arguments = try injectMap(config.arguments, id: id, surface: "arg", from: credentials)
        out.parameters = try injectMap(config.parameters, id: id, surface: "param", from: credentials)
        if config.requestURL == sentinel {
            let acct = account(id: id, surface: "url", key: "requestURL")
            guard let secret = try credentials.secret(for: acct) else {
                throw UploadError.missingCredential(acct)
            }
            out.requestURL = secret
        }
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
        try CredentialTransaction.purge(accounts(config, id: id), in: credentials)
    }

    /// True when a request URL carries something a credential could hide in.
    /// A bare `scheme://host/path` is safe to persist; a query string or
    /// embedded user-info is not.
    /// Expressed as an allowlist rather than a blocklist: URLComponents parses
    /// almost any string (it reads "not a url at all" as a bare path), so
    /// "failed to parse" is not a usable signal. Only a well-formed absolute
    /// http(s) URL with a host and no query or user-info is left in settings.
    static func urlNeedsProtecting(_ url: String) -> Bool {
        guard let c = URLComponents(string: url),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil,
              (c.query ?? "").isEmpty
        else { return true }
        return false
    }

    private static func account(id: String, surface: String, key: String) -> String {
        "\(id)/\(surface)/\(key)"
    }

    private static func stripMap(_ dict: [String: String], id: String, surface: String,
                                 into credentials: CredentialStore,
                                 written: inout [String]) throws -> [String: String] {
        var out = dict
        for (key, value) in dict where isSecretKey(key) && !value.isEmpty {
            let acct = account(id: id, surface: surface, key: key)
            try credentials.setSecret(value, for: acct)
            written.append(acct)
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
