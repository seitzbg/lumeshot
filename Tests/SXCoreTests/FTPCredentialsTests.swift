import Foundation
import Testing
@testable import SXCore

private final class DictCredentialStore: CredentialStore, @unchecked Sendable {
    var store: [String: String] = [:]
    func secret(for account: String) throws -> String? { store[account] }
    func setSecret(_ value: String, for account: String) throws { store[account] = value }
    func deleteSecret(for account: String) throws { store[account] = nil }
}

@Suite struct FTPCredentialsTests {
    @Test func storeThenLoadRoundTrips() throws {
        let creds = DictCredentialStore()
        try FTPCredentials.store(password: "pw", id: "d1", into: creds)
        let loaded = try FTPCredentials.load(id: "d1", from: creds)
        #expect(loaded == FTPSecret(password: "pw"))
        #expect(creds.store["d1/ftp/password"] == "pw")   // namespaced, nothing global
    }

    @Test func loadThrowsMissingCredentialWhenAbsent() throws {
        let creds = DictCredentialStore()
        #expect(throws: UploadError.self) {
            _ = try FTPCredentials.load(id: "d1", from: creds)
        }
    }

    @Test func purgeDeletesThePasswordKey() throws {
        let creds = DictCredentialStore()
        try FTPCredentials.store(password: "pw", id: "d1", into: creds)
        try FTPCredentials.purge(id: "d1", from: creds)
        #expect(creds.store.isEmpty)
    }

    @Test func purgeOnNeverStoredIDDoesNotThrow() throws {
        let creds = DictCredentialStore()
        try FTPCredentials.purge(id: "never-stored", from: creds)   // ignore not-found
    }
}
