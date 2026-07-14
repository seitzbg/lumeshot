import Foundation
import Testing
@testable import LumeshotCore

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

@Suite struct S3CredentialsTests {
    @Test func storeThenLoadRoundTrips() throws {
        let creds = DictCredentialStore()
        try S3Credentials.store(accessKeyID: "AK", secretAccessKey: "SK", id: "d1", into: creds)
        let loaded = try S3Credentials.load(id: "d1", from: creds)
        #expect(loaded == SigV4Credentials(accessKeyID: "AK", secretAccessKey: "SK"))
        // Namespaced accounts, nothing global.
        #expect(creds.store["d1/s3/accessKeyID"] == "AK")
        #expect(creds.store["d1/s3/secretAccessKey"] == "SK")
    }

    @Test func loadThrowsWhenSecretMissing() throws {
        let creds = DictCredentialStore()
        try creds.setSecret("AK", for: "d1/s3/accessKeyID")   // access key only
        #expect(throws: UploadError.self) {
            _ = try S3Credentials.load(id: "d1", from: creds)
        }
    }

    @Test func purgeDeletesBothAccounts() throws {
        let creds = DictCredentialStore()
        try S3Credentials.store(accessKeyID: "AK", secretAccessKey: "SK", id: "d1", into: creds)
        try S3Credentials.purge(id: "d1", from: creds)
        #expect(creds.store.isEmpty)
    }

    @Test func storeRollsBackTheFirstWriteWhenTheSecondFails() throws {
        let creds = FailingAfterNStore(failAt: 2)   // fails writing secretAccessKey (the 2nd setSecret)
        #expect(throws: (any Error).self) {
            try S3Credentials.store(accessKeyID: "AK", secretAccessKey: "SK", id: "d1", into: creds)
        }
        // The first write (accessKeyID) must be purged too — no orphan left behind.
        #expect(creds.store["d1/s3/accessKeyID"] == nil)
        #expect(creds.store["d1/s3/secretAccessKey"] == nil)
    }
}
