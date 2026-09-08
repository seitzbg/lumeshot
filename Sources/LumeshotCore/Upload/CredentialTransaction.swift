import Foundation

/// Aggregates per-account failures so a purge can attempt every key instead of
/// stopping at the first error and orphaning the rest.
public struct CredentialPurgeError: Error, Equatable, Sendable {
    public let failedAccounts: [String]
    public init(failedAccounts: [String]) { self.failedAccounts = failedAccounts }
}

/// Coordinates mutations that span the Keychain and settings.json.
///
/// Those two stores cannot be written atomically, so every ordering loses
/// something: purge-then-save can strand a destination whose credentials are
/// already gone, and save-then-purge can orphan credentials for a destination
/// that no longer exists. Reading the secrets before deleting them turns the
/// first case into a compensable transaction — if the settings write fails, put
/// them back.
public enum CredentialTransaction {
    /// Delete every account, attempting all of them, and return what was
    /// removed so a failed follow-up write can be rolled back.
    /// Accounts that held nothing are simply absent from the result.
    public static func purgeRestorable(_ accounts: [String],
                                       in store: CredentialStore) -> (saved: [String: String],
                                                                      error: CredentialPurgeError?) {
        var saved: [String: String] = [:]
        var failed: [String] = []
        for account in accounts {
            do {
                if let value = try store.secret(for: account) { saved[account] = value }
                try store.deleteSecret(for: account)
            } catch {
                failed.append(account)
            }
        }
        return (saved, failed.isEmpty ? nil : CredentialPurgeError(failedAccounts: failed))
    }

    /// Best-effort compensation for `purgeRestorable` when the dependent write
    /// failed. Failures here are unrecoverable by definition, so they are
    /// reported rather than thrown.
    @discardableResult
    public static func restore(_ saved: [String: String],
                               into store: CredentialStore) -> CredentialPurgeError? {
        var failed: [String] = []
        for (account, value) in saved {
            do { try store.setSecret(value, for: account) } catch { failed.append(account) }
        }
        return failed.isEmpty ? nil : CredentialPurgeError(failedAccounts: failed)
    }

    /// Delete every account, attempting all of them.
    public static func purge(_ accounts: [String], in store: CredentialStore) throws {
        if let error = purgeRestorable(accounts, in: store).error { throw error }
    }

    /// Reads the full before-picture of `accounts` so a failed edit can be undone
    /// exactly.
    ///
    /// Presence matters as much as value. Restoring only the accounts that held
    /// something leaves behind any account the failed edit introduced: changing
    /// an SFTP destination from a password to a private key and then failing to
    /// save settings left the restored password *and* the rejected key in the
    /// Keychain, and the transport prefers the key — so the destination silently
    /// used a credential the UI had just said was not applied.
    ///
    /// Throws rather than reporting an unreadable account as empty. The two are
    /// indistinguishable in the result, and treating a read failure as "held
    /// nothing" would turn the rollback into a deletion of a working credential.
    public static func snapshot(_ accounts: [String],
                                in store: CredentialStore) throws -> CredentialSnapshot {
        var values: [String: String] = [:]
        for account in accounts {
            if let value = try store.secret(for: account) { values[account] = value }
        }
        return CredentialSnapshot(accounts: accounts, values: values)
    }

    /// Puts the Keychain back exactly as `snapshot` found it: every account that
    /// held a value gets it back, and every account that did not is removed.
    /// Failures here are unrecoverable by definition, so they are reported.
    @discardableResult
    public static func rollback(to snapshot: CredentialSnapshot,
                                in store: CredentialStore) -> CredentialPurgeError? {
        var failed: [String] = []
        for account in snapshot.accounts {
            do {
                if let value = snapshot.values[account] {
                    try store.setSecret(value, for: account)
                } else {
                    try store.deleteSecret(for: account)
                }
            } catch {
                failed.append(account)
            }
        }
        return failed.isEmpty ? nil : CredentialPurgeError(failedAccounts: failed)
    }
}

/// The state of one destination's Keychain accounts at a point in time —
/// which accounts exist at all, and what the occupied ones hold.
public struct CredentialSnapshot: Sendable {
    public let accounts: [String]
    public let values: [String: String]

    public init(accounts: [String], values: [String: String]) {
        self.accounts = accounts
        self.values = values
    }
}
