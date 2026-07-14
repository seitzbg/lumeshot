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
}
