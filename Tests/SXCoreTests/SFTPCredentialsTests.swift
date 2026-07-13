import Foundation
import Testing
@testable import SXCore

private final class DictCredentialStore: CredentialStore, @unchecked Sendable {
    var store: [String: String] = [:]
    func secret(for account: String) throws -> String? { store[account] }
    func setSecret(_ value: String, for account: String) throws { store[account] = value }
    func deleteSecret(for account: String) throws { store[account] = nil }
}

private final class FailingAfterNStore: CredentialStore, @unchecked Sendable {
    var store: [String: String] = [:]
    private var callCount = 0
    private let failAt: Int
    init(failAt: Int) { self.failAt = failAt }
    func secret(for account: String) throws -> String? { store[account] }
    func setSecret(_ value: String, for account: String) throws {
        callCount += 1
        if callCount == failAt { throw UploadError.transport("simulated failure") }
        store[account] = value
    }
    func deleteSecret(for account: String) throws { store[account] = nil }
}

@Suite struct SFTPCredentialsTests {
    @Test func storeThenLoadRoundTripsAllThreeFields() throws {
        let creds = DictCredentialStore()
        try SFTPCredentials.store(password: "pw", privateKeyPEM: "-----BEGIN KEY-----",
                                  passphrase: "phrase", id: "d1", into: creds)
        let loaded = try SFTPCredentials.load(id: "d1", from: creds)
        #expect(loaded == SFTPSecret(password: "pw", privateKeyPEM: "-----BEGIN KEY-----",
                                     passphrase: "phrase"))
        // Namespaced accounts, nothing global.
        #expect(creds.store["d1/sftp/password"] == "pw")
        #expect(creds.store["d1/sftp/privateKey"] == "-----BEGIN KEY-----")
        #expect(creds.store["d1/sftp/passphrase"] == "phrase")
    }

    @Test func passwordOnlyLeavesKeyAndPassphraseNil() throws {
        let creds = DictCredentialStore()
        try SFTPCredentials.store(password: "pw", privateKeyPEM: nil, passphrase: nil,
                                  id: "d1", into: creds)
        let loaded = try SFTPCredentials.load(id: "d1", from: creds)
        #expect(loaded.password == "pw")
        #expect(loaded.privateKeyPEM == nil)
        #expect(loaded.passphrase == nil)
        #expect(creds.store["d1/sftp/privateKey"] == nil)   // only the non-nil ones are written
    }

    @Test func keyOnlyLeavesPasswordNil() throws {
        let creds = DictCredentialStore()
        try SFTPCredentials.store(password: nil, privateKeyPEM: "-----BEGIN KEY-----",
                                  passphrase: nil, id: "d1", into: creds)
        let loaded = try SFTPCredentials.load(id: "d1", from: creds)
        #expect(loaded.password == nil)
        #expect(loaded.privateKeyPEM == "-----BEGIN KEY-----")
    }

    @Test func keyPlusPassphraseRoundTrips() throws {
        let creds = DictCredentialStore()
        try SFTPCredentials.store(password: nil, privateKeyPEM: "-----BEGIN KEY-----",
                                  passphrase: "hunter2", id: "d1", into: creds)
        let loaded = try SFTPCredentials.load(id: "d1", from: creds)
        #expect(loaded.privateKeyPEM == "-----BEGIN KEY-----")
        #expect(loaded.passphrase == "hunter2")
    }

    @Test func loadWithNothingStoredReturnsAllNilSecret() throws {
        let creds = DictCredentialStore()
        let loaded = try SFTPCredentials.load(id: "missing", from: creds)
        #expect(loaded == SFTPSecret(password: nil, privateKeyPEM: nil, passphrase: nil))
    }

    @Test func purgeDeletesAllThreeKeys() throws {
        let creds = DictCredentialStore()
        try SFTPCredentials.store(password: "pw", privateKeyPEM: "key", passphrase: "phrase",
                                  id: "d1", into: creds)
        try SFTPCredentials.purge(id: "d1", from: creds)
        #expect(creds.store.isEmpty)
    }

    @Test func purgeOnNeverStoredIDDoesNotThrow() throws {
        let creds = DictCredentialStore()
        try SFTPCredentials.purge(id: "never-stored", from: creds)   // ignore not-found
    }

    @Test func storeRollsBackAllWritesWhenALaterOneFails() throws {
        let creds = FailingAfterNStore(failAt: 2)   // fails writing privateKeyPEM (the 2nd setSecret)
        #expect(throws: (any Error).self) {
            try SFTPCredentials.store(password: "pw", privateKeyPEM: "key", passphrase: "phrase",
                                      id: "d1", into: creds)
        }
        // The first write (password) must be purged too — no orphan left behind.
        #expect(creds.store["d1/sftp/password"] == nil)
        #expect(creds.store["d1/sftp/privateKey"] == nil)
        #expect(creds.store["d1/sftp/passphrase"] == nil)
    }
}
