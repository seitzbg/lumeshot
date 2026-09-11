import Foundation
import Testing
import LumeshotCore
@testable import LumeshotUpload
@testable import LumeshotApp

/// A credential store whose writes can be made to fail for one chosen account,
/// so an edit can be interrupted exactly where the real Keychain would refuse.
private final class FlakyCredentials: CredentialStore, @unchecked Sendable {
    var values: [String: String] = [:]
    var failWriteFor: String?
    var failReadFor: String?

    func secret(for account: String) throws -> String? {
        if account == failReadFor { throw UploadError.transport("Injected read failure") }
        return values[account]
    }
    func setSecret(_ value: String, for account: String) throws {
        // Fails once, then behaves — a transient Keychain refusal. A permanently
        // failing account would also defeat the rollback, which would test the
        // double rather than the code.
        if account == failWriteFor {
            failWriteFor = nil
            throw UploadError.transport("Injected write failure")
        }
        values[account] = value
    }
    func deleteSecret(for account: String) throws { values.removeValue(forKey: account) }
}

@Suite @MainActor struct DestinationEditRollbackTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sftpConfig(pin: String? = nil) -> SFTPConfig {
        SFTPConfig(host: "example.com", username: "user", remoteDirectory: "/uploads",
                   publicURLBase: "https://example.com/uploads", knownHostKey: pin)
    }

    /// Renames the destination without touching its credentials or endpoint.
    private func renameSFTP(_ model: DestinationsModel, password: String = "", key: String = "") {
        model.saveSFTP(id: "dest", name: "Renamed", host: "example.com", port: 22, username: "user",
                       remoteDirectory: "/uploads", publicURLBase: "https://example.com/uploads",
                       password: password, privateKeyPEM: key, passphrase: "")
    }

    private func model(in dir: URL, credentials: CredentialStore,
                       destination: UploadDestination) throws -> (DestinationsModel, SettingsStore) {
        let store = SettingsStore(fileURL: dir.appendingPathComponent("settings.json"))
        var settings = AppSettings.default
        settings.upload = settings.upload.addingOrUpdating(destination)
        try store.save(settings)
        return (DestinationsModel(store: store, credentials: credentials, onChange: {}), store)
    }

    /// Makes the next settings write fail: an atomic file write cannot replace a
    /// directory.
    private func blockSettingsWrite(_ store: SettingsStore) throws {
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
    }

    /// S3 stores two accounts and purges both if the second write fails, so a
    /// failed edit used to destroy credentials that were working beforehand.
    @Test func failedCredentialWriteKeepsTheWorkingCredentials() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let credentials = FlakyCredentials()
        credentials.values = ["dest/s3/accessKeyID": "old-id", "dest/s3/secretAccessKey": "old-secret"]
        let destination = UploadDestination(id: "dest", name: "S3", kind: .s3,
            s3Config: S3Config(region: "us-east-1", endpoint: "s3.example.com", bucket: "bucket"))
        let (model, _) = try model(in: dir, credentials: credentials, destination: destination)

        credentials.failWriteFor = "dest/s3/secretAccessKey"
        model.saveS3(id: "dest", name: "S3", region: "us-east-1", endpoint: "s3.example.com",
                     bucket: "bucket", prefix: "", accessKeyID: "new-id",
                     secretAccessKey: "new-secret", pathStyle: true, acl: "", customDomain: "")

        #expect(model.saveError != nil)
        #expect(credentials.values["dest/s3/accessKeyID"] == "old-id")
        #expect(credentials.values["dest/s3/secretAccessKey"] == "old-secret")
    }

    /// Restoring only the accounts that previously held something left the
    /// rejected new one in place beside them. The transport prefers a private
    /// key over a password, so the destination would have authenticated with a
    /// credential the UI had just said was not applied.
    @Test func failedSettingsWriteLeavesNoRejectedCredentialBehind() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let credentials = FlakyCredentials()
        credentials.values = ["dest/sftp/password": "old-password"]
        let destination = UploadDestination(id: "dest", name: "SFTP", kind: .sftp,
                                            sftpConfig: sftpConfig())
        let (model, store) = try model(in: dir, credentials: credentials, destination: destination)

        try blockSettingsWrite(store)
        renameSFTP(model, key: "new-key")

        #expect(model.saveError != nil)
        #expect(credentials.values == ["dest/sftp/password": "old-password"])
    }

    /// An account that cannot be read is indistinguishable from an empty one, so
    /// the edit must not start: rolling back from that snapshot would delete a
    /// credential that was merely unreadable.
    @Test func unreadableCredentialAbortsTheEditInsteadOfGuessing() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let credentials = FlakyCredentials()
        credentials.values = ["dest/sftp/password": "old-password"]
        credentials.failReadFor = "dest/sftp/password"
        let destination = UploadDestination(id: "dest", name: "SFTP", kind: .sftp,
                                            sftpConfig: sftpConfig())
        let (model, _) = try model(in: dir, credentials: credentials, destination: destination)

        renameSFTP(model, key: "new-key")

        #expect(model.saveError != nil)
        #expect(credentials.values == ["dest/sftp/password": "old-password"])
    }

    /// An upload can pin a host key while Preferences is already open. The edit
    /// must not carry the stale, unpinned copy it loaded back over the top.
    @Test func editingPreservesAPinLearnedSincePreferencesOpened() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let destination = UploadDestination(id: "dest", name: "SFTP", kind: .sftp,
                                            sftpConfig: sftpConfig())
        let (model, store) = try model(in: dir, credentials: FlakyCredentials(),
                                       destination: destination)

        // The pin lands on disk after the model has taken its copy.
        var settings = store.loadOrDefault().0
        settings.upload.destinations[0].sftpConfig?.knownHostKey = "SHA256:pinned"
        try store.save(settings)

        renameSFTP(model)

        let saved = store.loadOrDefault().0.upload.destinations[0]
        #expect(saved.name == "Renamed")
        #expect(saved.sftpConfig?.knownHostKey == "SHA256:pinned")
    }

    /// The fingerprint belongs to the endpoint that presented it. An upload can
    /// still be connecting when the destination is edited to point elsewhere, and
    /// keying the write on the id alone stapled this server's key onto the new
    /// one — after which every connection there failed as a host-key mismatch.
    @Test func aPinIsNotWrittenOntoAnEndpointThatDidNotPresentIt() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(fileURL: dir.appendingPathComponent("settings.json"))
        let destination = UploadDestination(id: "dest", name: "SFTP", kind: .sftp,
                                            sftpConfig: sftpConfig())
        var settings = AppSettings.default
        settings.upload = settings.upload.addingOrUpdating(destination)
        try store.save(settings)

        let service = UploadService(credentials: FlakyCredentials(), settingsStore: store)
        let uploader = try #require(try service.uploader(for: destination) as? SFTPUploader)

        // The destination is repointed while the upload is still connecting.
        settings.upload.destinations[0].sftpConfig?.host = "elsewhere.example.com"
        try store.save(settings)

        _ = uploader.rememberHostKey("SHA256:from-the-original-host")

        let saved = store.loadOrDefault().0.upload.destinations[0].sftpConfig
        #expect(saved?.host == "elsewhere.example.com")
        #expect(saved?.knownHostKey == nil)
    }

    /// The ordinary case still pins: same destination, same endpoint, no pin yet.
    @Test func aPinIsWrittenWhenTheEndpointIsUnchanged() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(fileURL: dir.appendingPathComponent("settings.json"))
        let destination = UploadDestination(id: "dest", name: "SFTP", kind: .sftp,
                                            sftpConfig: sftpConfig())
        var settings = AppSettings.default
        settings.upload = settings.upload.addingOrUpdating(destination)
        try store.save(settings)

        let service = UploadService(credentials: FlakyCredentials(), settingsStore: store)
        let uploader = try #require(try service.uploader(for: destination) as? SFTPUploader)
        _ = uploader.rememberHostKey("SHA256:learned")

        #expect(store.loadOrDefault().0.upload.destinations[0].sftpConfig?.knownHostKey
                == "SHA256:learned")
    }

    /// Moving the destination to a different server must not carry the old
    /// server's fingerprint with it — including when only the port changes.
    @Test func movingToAnotherEndpointClearsThePin() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let destination = UploadDestination(id: "dest", name: "SFTP", kind: .sftp,
                                            sftpConfig: sftpConfig(pin: "SHA256:pinned"))
        let (model, store) = try model(in: dir, credentials: FlakyCredentials(),
                                       destination: destination)

        model.saveSFTP(id: "dest", name: "SFTP", host: "example.com", port: 2222, username: "user",
                       remoteDirectory: "/uploads", publicURLBase: "https://example.com/uploads",
                       password: "", privateKeyPEM: "", passphrase: "")

        #expect(store.loadOrDefault().0.upload.destinations[0].sftpConfig?.knownHostKey == nil)
    }
}
