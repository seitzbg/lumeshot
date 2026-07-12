import Foundation
import Testing
@testable import SXCore

@Suite struct FTPConfigTests {
    @Test func roundTripsThroughJSON() throws {
        let config = FTPConfig(host: "ftp.example.com", port: 2121, username: "bob",
                               remoteDirectory: "/uploads",
                               publicURLBase: "https://cdn.example.com/uploads", useTLS: true)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(FTPConfig.self, from: data)
        #expect(decoded == config)
    }

    @Test func defaultsArePort21AndNoTLS() {
        let config = FTPConfig(host: "h", username: "u", remoteDirectory: "/d",
                               publicURLBase: "https://x.example.com/")
        #expect(config.port == 21)
        #expect(config.useTLS == false)
    }
}
