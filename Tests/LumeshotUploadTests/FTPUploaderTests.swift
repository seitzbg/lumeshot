import Foundation
import Testing
@testable import LumeshotUpload
import LumeshotCore

private final class FakeFTPTransport: FTPTransport, @unchecked Sendable {
    var receivedData: Data?
    var receivedURL: String?
    var receivedUsername: String?
    var receivedPassword: String?
    var receivedUseTLS: Bool?
    var errorToThrow: Error?

    func upload(_ data: Data, to url: String, username: String, password: String,
               useTLS: Bool) async throws {
        receivedData = data
        receivedURL = url
        receivedUsername = username
        receivedPassword = password
        receivedUseTLS = useTLS
        if let errorToThrow { throw errorToThrow }
    }
}

@Suite struct FTPUploaderTests {
    private var config: FTPConfig {
        FTPConfig(host: "ftp.example.com", port: 21, username: "bob",
                 remoteDirectory: "/uploads", publicURLBase: "https://cdn.example.com/uploads")
    }
    private let secret = FTPSecret(password: "s3cr3t")

    private func png() -> FilePart {
        FilePart(fieldName: "file", filename: "shot.png", mimeType: "image/png", data: Data([1, 2, 3]))
    }

    @Test func uploadsToTheDerivedFTPURLAndReturnsResultURL() async throws {
        let fake = FakeFTPTransport()
        let uploader = FTPUploader(config: config, secret: secret, transport: fake)
        let result = try await uploader.upload(png())
        #expect(fake.receivedURL == "ftp://ftp.example.com:21/uploads/shot.png")
        #expect(fake.receivedData == Data([1, 2, 3]))
        #expect(fake.receivedUsername == "bob")
        #expect(fake.receivedPassword == "s3cr3t")
        #expect(fake.receivedUseTLS == false)
        #expect(result.url == "https://cdn.example.com/uploads/shot.png")
    }

    @Test func useTLSIsPassedThroughToTheTransport() async throws {
        var tlsConfig = config
        tlsConfig.useTLS = true
        let fake = FakeFTPTransport()
        let uploader = FTPUploader(config: tlsConfig, secret: secret, transport: fake)
        _ = try await uploader.upload(png())
        #expect(fake.receivedUseTLS == true)
    }

    @Test func remoteDirectoryWithoutLeadingSlashIsRootedInTheURL() async throws {
        var relative = config
        relative.remoteDirectory = "uploads"
        let fake = FakeFTPTransport()
        let uploader = FTPUploader(config: relative, secret: secret, transport: fake)
        _ = try await uploader.upload(png())
        #expect(fake.receivedURL == "ftp://ftp.example.com:21/uploads/shot.png")
    }

    @Test func transportFailureThrowsAndSurfaces() async {
        let fake = FakeFTPTransport()
        fake.errorToThrow = UploadError.transport("FTP upload failed: connection refused")
        let uploader = FTPUploader(config: config, secret: secret, transport: fake)
        await #expect(throws: UploadError.self) {
            _ = try await uploader.upload(png())
        }
    }
}
