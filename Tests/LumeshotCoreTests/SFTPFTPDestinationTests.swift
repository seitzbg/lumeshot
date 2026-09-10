import Foundation
import Testing
@testable import LumeshotCore

@Suite struct SFTPFTPDestinationTests {
    @Test func sftpDestinationRoundTripsThroughUploadSettings() throws {
        let config = SFTPConfig(host: "sftp.example.com", port: 2222, username: "bob",
                                remoteDirectory: "/home/bob/uploads",
                                publicURLBase: "https://cdn.example.com/uploads")
        let dest = UploadDestination(id: "d1", name: "My SFTP", kind: .sftp, sftpConfig: config)
        let settings = UploadSettings(uploadAfterCapture: true, activeDestinationID: "d1",
                                      destinations: [dest])

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(UploadSettings.self, from: data)

        #expect(decoded == settings)
        #expect(decoded.destinations.first?.kind == .sftp)
        #expect(decoded.destinations.first?.sftpConfig?.host == "sftp.example.com")
        #expect(decoded.destinations.first?.ftpConfig == nil)
    }

    @Test func ftpDestinationRoundTripsThroughUploadSettings() throws {
        let config = FTPConfig(host: "ftp.example.com", username: "bob",
                               remoteDirectory: "/uploads",
                               publicURLBase: "https://cdn.example.com/uploads", useTLS: true)
        let dest = UploadDestination(id: "d2", name: "My FTP", kind: .ftp, ftpConfig: config)
        let settings = UploadSettings(uploadAfterCapture: false, activeDestinationID: "d2",
                                      destinations: [dest])

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(UploadSettings.self, from: data)

        #expect(decoded == settings)
        #expect(decoded.destinations.first?.kind == .ftp)
        #expect(decoded.destinations.first?.ftpConfig?.useTLS == true)
        #expect(decoded.destinations.first?.sftpConfig == nil)
    }

    /// The invariant `docs/smoke-m5a.md` checked by grepping the real
    /// settings.json: secrets live in the Keychain, so the encoded settings — the
    /// exact bytes that file is written from — must contain no credential
    /// material for either destination kind, whatever else gets added to these
    /// config types later.
    @Test func encodedSettingsCarryNoCredentialMaterialForSFTPOrFTP() throws {
        let sftp = UploadDestination(
            id: "d1", name: "My SFTP", kind: .sftp,
            sftpConfig: SFTPConfig(host: "sftp.example.com", port: 2222, username: "bob",
                                   remoteDirectory: "/home/bob/uploads",
                                   publicURLBase: "https://cdn.example.com/uploads",
                                   knownHostKey: "SHA256:abc"))
        let ftp = UploadDestination(
            id: "d2", name: "My FTP", kind: .ftp,
            ftpConfig: FTPConfig(host: "ftp.example.com", username: "bob",
                                 remoteDirectory: "/uploads",
                                 publicURLBase: "https://cdn.example.com/uploads", useTLS: true))
        let settings = UploadSettings(uploadAfterCapture: true, activeDestinationID: "d1",
                                      destinations: [sftp, ftp])

        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).lowercased()

        for forbidden in ["password", "privatekey", "passphrase", "begin openssh", "secret"] {
            #expect(!json.contains(forbidden), "settings encoding leaked \(forbidden)")
        }
        // The pinned host key is public material and is meant to stay readable.
        #expect(json.contains("sha256:abc"))
    }
}
