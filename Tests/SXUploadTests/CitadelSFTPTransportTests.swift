import Foundation
import Testing
@testable import SXUpload
import SXCore

/// `CitadelSFTPTransport` is otherwise Mac-smoke-only (it needs a live SSH
/// server to exercise connect/write/close). Key-parsing, however, happens
/// entirely before any network I/O, so a malformed key is unit-testable here
/// and runs in CI with no live server involved.
@Suite struct CitadelSFTPTransportTests {
    @Test func malformedPrivateKeyThrowsATypedUploadError() async {
        let transport = CitadelSFTPTransport()
        let secret = SFTPSecret(
            password: nil,
            privateKeyPEM: "-----BEGIN OPENSSH PRIVATE KEY-----\nnot-a-real-key\n-----END OPENSSH PRIVATE KEY-----",
            passphrase: nil)

        do {
            try await transport.upload(Data("x".utf8), to: "/tmp/f", host: "127.0.0.1", port: 1,
                                       username: "u", secret: secret)
            Issue.record("expected upload to throw for a malformed private key")
        } catch let error as UploadError {
            guard case .missingCredential = error else {
                Issue.record("expected UploadError.missingCredential, got \(error)")
                return
            }
        } catch {
            Issue.record("expected a typed UploadError, got \(type(of: error)): \(error)")
        }
    }
}
