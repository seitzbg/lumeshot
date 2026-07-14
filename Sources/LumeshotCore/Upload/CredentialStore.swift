import Foundation

/// Abstracts secret storage so uploaders can be tested without the Keychain.
/// `account` is the storage key (e.g. "<destinationID>/token").
public protocol CredentialStore: Sendable {
    func secret(for account: String) throws -> String?
    func setSecret(_ value: String, for account: String) throws
    func deleteSecret(for account: String) throws
}
