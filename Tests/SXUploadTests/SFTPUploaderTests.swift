import Foundation
import Testing
@testable import SXUpload
import SXCore

private final class FakeSFTPTransport: SFTPTransport, @unchecked Sendable {
    var receivedData: Data?
    var receivedRemotePath: String?
    var receivedHost: String?
    var receivedPort: Int?
    var receivedUsername: String?
    var receivedSecret: SFTPSecret?
    var errorToThrow: Error?

    func upload(_ data: Data, to remotePath: String, host: String, port: Int,
               username: String, secret: SFTPSecret) async throws {
        receivedData = data
        receivedRemotePath = remotePath
        receivedHost = host
        receivedPort = port
        receivedUsername = username
        receivedSecret = secret
        if let errorToThrow { throw errorToThrow }
    }
}

@Suite struct SFTPUploaderTests {
    private var config: SFTPConfig {
        SFTPConfig(host: "sftp.example.com", port: 2222, username: "bob",
                  remoteDirectory: "/home/bob/uploads", publicURLBase: "https://cdn.example.com/uploads")
    }
    private let secret = SFTPSecret(password: "s3cr3t", privateKeyPEM: nil, passphrase: nil)

    private func png() -> FilePart {
        FilePart(fieldName: "file", filename: "shot.png", mimeType: "image/png", data: Data([1, 2, 3]))
    }

    @Test func uploadsToTheDerivedRemotePathAndReturnsResultURL() async throws {
        let fake = FakeSFTPTransport()
        let uploader = SFTPUploader(config: config, secret: secret, transport: fake)
        let result = try await uploader.upload(png())
        #expect(fake.receivedRemotePath == "/home/bob/uploads/shot.png")
        #expect(fake.receivedHost == "sftp.example.com")
        #expect(fake.receivedPort == 2222)
        #expect(fake.receivedUsername == "bob")
        #expect(fake.receivedData == Data([1, 2, 3]))
        #expect(result.url == "https://cdn.example.com/uploads/shot.png")
    }

    @Test func passesTheSecretThroughUnchanged() async throws {
        let fake = FakeSFTPTransport()
        let keySecret = SFTPSecret(password: nil, privateKeyPEM: "-----BEGIN KEY-----", passphrase: "hunter2")
        let uploader = SFTPUploader(config: config, secret: keySecret, transport: fake)
        _ = try await uploader.upload(png())
        #expect(fake.receivedSecret == keySecret)
    }

    @Test func remoteDirectoryTrailingSlashIsTrimmed() async throws {
        var trailing = config
        trailing.remoteDirectory = "/home/bob/uploads/"
        let fake = FakeSFTPTransport()
        let uploader = SFTPUploader(config: trailing, secret: secret, transport: fake)
        _ = try await uploader.upload(png())
        #expect(fake.receivedRemotePath == "/home/bob/uploads/shot.png")
    }

    @Test func transportFailureThrowsAndSurfaces() async {
        let fake = FakeSFTPTransport()
        fake.errorToThrow = UploadError.transport("SFTP write failed: connection reset")
        let uploader = SFTPUploader(config: config, secret: secret, transport: fake)
        await #expect(throws: UploadError.self) {
            _ = try await uploader.upload(png())
        }
    }

    @Test func missingCredentialIsSurfacedByTheTransport() async {
        // The uploader itself never validates the secret's contents — that
        // enforcement lives in CitadelSFTPTransport (Task 8, smoke-only). Here
        // we assert the uploader simply propagates whatever the transport throws.
        let fake = FakeSFTPTransport()
        fake.errorToThrow = UploadError.missingCredential("SFTP destination has neither password nor private key")
        let emptySecret = SFTPSecret(password: nil, privateKeyPEM: nil, passphrase: nil)
        let uploader = SFTPUploader(config: config, secret: emptySecret, transport: fake)
        await #expect(throws: UploadError.self) {
            _ = try await uploader.upload(png())
        }
    }
}
