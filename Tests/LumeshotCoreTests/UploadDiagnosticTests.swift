import Foundation
import Testing
@testable import LumeshotCore

@Suite struct UploadDiagnosticTests {
    /// The log file lives in ~/Library/Logs, outside the Keychain. A server that
    /// echoes the request back on an error can therefore write a credential to
    /// it, so the response body must not be interpolated into a log line.
    @Test func theResponseBodyNeverReachesDiagnostics() {
        let error = UploadError.http(status: 400,
                                     body: #"{"apikey":"sk-live-must-not-be-logged","deletehash":"dh-secret"}"#)
        let text = UploadFeedback.diagnostic(for: error)
        #expect(!text.contains("sk-live-must-not-be-logged"))
        #expect(!text.contains("dh-secret"))
        #expect(!text.contains("apikey"))
        #expect(text.contains("400"))
    }

    /// The reason an SFTP or FTP upload failed is composed by our own transports
    /// from the underlying error, so it carries nothing the server sent — and it
    /// is the whole diagnostic value of the log line.
    @Test func transportReasonsSurviveRedaction() {
        let text = UploadFeedback.diagnostic(for: UploadError.transport("SFTP connect failed: handshake timeout"))
        #expect(text.contains("handshake timeout"))
    }

    /// The user-facing text is unchanged and still hides the body.
    @Test func userFacingTextStillHidesTheBody() {
        let error = UploadError.http(status: 401, body: "token=leaked")
        #expect(!UploadFeedback.message(for: error).contains("leaked"))
    }
}
