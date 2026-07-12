import Foundation
import Testing
@testable import SXCore

@Suite struct SFTPConfigTests {
    @Test func roundTripsThroughJSON() throws {
        let config = SFTPConfig(host: "sftp.example.com", port: 2222, username: "bob",
                                remoteDirectory: "/home/bob/uploads",
                                publicURLBase: "https://cdn.example.com/uploads")
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SFTPConfig.self, from: data)
        #expect(decoded == config)
    }

    @Test func defaultPortIs22() {
        let config = SFTPConfig(host: "h", username: "u", remoteDirectory: "/d",
                                publicURLBase: "https://x.example.com/")
        #expect(config.port == 22)
    }
}
