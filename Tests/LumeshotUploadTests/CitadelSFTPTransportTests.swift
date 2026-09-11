import Foundation
import Testing
import Citadel
@testable import LumeshotUpload
import LumeshotCore

/// An error whose description quotes a "server message", standing in for a
/// Citadel `SFTPMessage.Status` (whose memberwise init is internal to Citadel,
/// so it cannot be constructed here). The leak string matches the shape Citadel
/// actually produces: `{reqId}(code: SSH_FX_..., lang#'<server message>')`.
private struct FakeServerError: Error, CustomStringConvertible {
    var description: String {
        "{1}(code: SSH_FX_PERMISSION_DENIED, en#'rejected token=REVIEW_SYNTHETIC_SECRET')"
    }
}

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
                                       username: "u", secret: secret,
                                       knownHostKey: nil, rememberHostKey: { _ in .accepted })
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

    /// The transport reason is written to ~/Library/Logs/Lumeshot.log via
    /// `UploadFeedback.diagnostic`. An SFTP server's status message can echo a
    /// remote path or a token, so it must never be interpolated into that reason
    /// — only the typed error/status survives.
    @Test func redactedReasonDropsServerSuppliedText() {
        let reason = CitadelSFTPTransport.redactedReason(FakeServerError())
        #expect(!reason.contains("REVIEW_SYNTHETIC_SECRET"))
        #expect(!reason.contains("rejected token"))
        #expect(reason == "FakeServerError")   // type only, no free-form description
    }

    /// The whole diagnostic value is naming the actual cause, so a typed Citadel
    /// error keeps its category. `SFTPError.connectionClosed` is a real Citadel
    /// error with no server text.
    @Test func redactedReasonKeepsTypedCategory() {
        #expect(CitadelSFTPTransport.redactedReason(SFTPError.connectionClosed) == "SFTPError.connectionClosed")
        let urlReason = CitadelSFTPTransport.redactedReason(URLError(.timedOut))
        #expect(urlReason.contains("URLError"))
        #expect(urlReason.contains("\(URLError.timedOut.rawValue)"))
    }

    /// End to end: a redacted reason wrapped as `.transport` and passed through
    /// the production diagnostic formatter carries no server text.
    @Test func aWrappedRedactedReasonSurvivesDiagnosticsWithoutLeaking() {
        let reason = CitadelSFTPTransport.redactedReason(FakeServerError())
        let diag = UploadFeedback.diagnostic(for: UploadError.transport("SFTP write failed: \(reason)"))
        #expect(!diag.contains("REVIEW_SYNTHETIC_SECRET"))
        #expect(diag.contains("SFTP write failed"))   // the app-authored prefix stays
    }
}
