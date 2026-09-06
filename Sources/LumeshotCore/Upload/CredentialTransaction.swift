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
}
