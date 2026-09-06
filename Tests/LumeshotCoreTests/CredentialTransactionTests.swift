import Foundation
import Testing
@testable import LumeshotCore

/// In-memory store that can be told to fail on specific accounts, so the
/// compensating paths are exercised rather than assumed.
private final class FaultyCredentialStore: CredentialStore, @unchecked Sendable {
    var store: [String: String] = [:]
    var failReadsFor: Set<String> = []
    var failDeletesFor: Set<String> = []
    var failWritesFor: Set<String> = []

    struct Boom: Error {}

    func secret(for account: String) throws -> String? {
        if failReadsFor.contains(account) { throw Boom() }
        return store[account]
    }
    func setSecret(_ value: String, for account: String) throws {
        if failWritesFor.contains(account) { throw Boom() }
        store[account] = value
    }
    func deleteSecret(for account: String) throws {
        if failDeletesFor.contains(account) { throw Boom() }
        store[account] = nil
    }
}

@Suite struct CredentialTransactionTests {
    private func seeded() -> FaultyCredentialStore {
        let s = FaultyCredentialStore()
        s.store = ["d1/s3/accessKeyID": "AK", "d1/s3/secretAccessKey": "SK"]
        return s
    }

    @Test func purgeRestorableReturnsWhatItDeleted() {
        let store = seeded()
        let (saved, error) = CredentialTransaction.purgeRestorable(
            S3Credentials.accounts(id: "d1"), in: store)
        #expect(error == nil)
        #expect(store.store.isEmpty)
        #expect(saved == ["d1/s3/accessKeyID": "AK", "d1/s3/secretAccessKey": "SK"])
    }

    @Test func restorePutsThemBackExactly() {
        let store = seeded()
        let (saved, _) = CredentialTransaction.purgeRestorable(
            S3Credentials.accounts(id: "d1"), in: store)
        #expect(CredentialTransaction.restore(saved, into: store) == nil)
        #expect(store.store == ["d1/s3/accessKeyID": "AK", "d1/s3/secretAccessKey": "SK"])
    }

    /// The old purge stopped at the first throwing key, orphaning the rest.
    @Test func aFailedDeleteDoesNotAbandonTheRemainingAccounts() {
        let store = seeded()
        store.failDeletesFor = ["d1/s3/accessKeyID"]
        let (_, error) = CredentialTransaction.purgeRestorable(
            S3Credentials.accounts(id: "d1"), in: store)
        #expect(error?.failedAccounts == ["d1/s3/accessKeyID"])
        #expect(store.store["d1/s3/secretAccessKey"] == nil)   // still attempted
    }

    @Test func purgeThrowsAnAggregateOfEveryFailure() {
        let store = seeded()
        store.failDeletesFor = ["d1/s3/accessKeyID", "d1/s3/secretAccessKey"]
        #expect(throws: CredentialPurgeError(
            failedAccounts: ["d1/s3/accessKeyID", "d1/s3/secretAccessKey"])) {
            try CredentialTransaction.purge(S3Credentials.accounts(id: "d1"), in: store)
        }
    }

    @Test func purgingAccountsThatWereNeverWrittenIsNotAnError() {
        let store = FaultyCredentialStore()
        let (saved, error) = CredentialTransaction.purgeRestorable(
            SFTPCredentials.accounts(id: "nope"), in: store)
        #expect(error == nil)
        #expect(saved.isEmpty)
    }
}

@Suite struct DestinationSecretAccountsTests {
    @Test func eachKindReportsItsOwnAccounts() {
        let s3 = UploadDestination(id: "d", name: "s3", kind: .s3,
                                   s3Config: S3Config(region: "r", endpoint: "", bucket: "b",
                                                      objectPrefix: "", addressingStyle: .path,
                                                      acl: nil, customDomain: nil))
        #expect(Set(s3.secretAccounts) == Set(S3Credentials.accounts(id: "d")))

        let picsur = UploadDestination(id: "d", name: "p", kind: .picsur,
                                       picsurConfig: PicsurConfig(host: "https://h"))
        #expect(picsur.secretAccounts == PicsurCredentials.accounts(id: "d"))

        // Anonymous Imgur holds no secret at all.
        #expect(UploadDestination(id: "d", name: "i", kind: .imgur,
                                  imgurClientID: "CID").secretAccounts.isEmpty)
    }

    @Test func customUploaderAccountsCoverEverySentinelSurface() throws {
        let store = FaultyCredentialStore()
        var config = CustomUploaderConfig(requestURL: "https://up")
        config.headers = ["Authorization": "S1", "Accept": "json"]
        config.parameters = ["api_key": "S2"]
        config.data = #"{"t":"S3"}"#
        let stripped = try SecretVault.strip(config, id: "d1", into: store)
        let dest = UploadDestination(id: "d1", name: "c", kind: .customUploader,
                                     customUploader: stripped)
        #expect(Set(dest.secretAccounts) == Set(store.store.keys))
    }

    /// A write that fails partway must not leave the earlier ones behind.
    @Test func aPartialStripRollsBack() {
        let store = FaultyCredentialStore()
        store.failWritesFor = ["d1/data/body"]
        var config = CustomUploaderConfig(requestURL: "https://up")
        config.headers = ["Authorization": "S1"]
        config.data = #"{"t":"S2"}"#
        #expect(throws: (any Error).self) {
            try SecretVault.strip(config, id: "d1", into: store)
        }
        #expect(store.store.isEmpty)
    }
}
