import Foundation
import Testing
@testable import LumeshotUpload
@testable import LumeshotCore

@Suite struct PicsurUploaderTests {
    private func upload(config: PicsurConfig, body: String,
                        capture: @escaping @Sendable (PreparedRequest) -> Void = { _ in })
        async throws -> UploadResult {
        let http = FakeHTTP(response: HTTPResponse(status: 200, headers: [:], body: Data(body.utf8)),
                            capture: capture)
        let up = PicsurUploader(config: config, secret: PicsurSecret(apiKey: "KEY"), http: http)
        let file = FilePart(fieldName: "file", filename: "a.png",
                            mimeType: "image/png", data: Data([9]))
        return try await up.upload(file)
    }

    private let success = #"{"success":true,"data":{"id":"abc123","delete_key":"dk"}}"#

    @Test func buildsPicsurRequest() async throws {
        _ = try await upload(config: PicsurConfig(host: "https://pic.bsd-unix.net"),
                             body: success) { req in
            #expect(req.url == "https://pic.bsd-unix.net/api/image/upload")
            #expect(req.headers["Authorization"] == "Api-Key KEY")
            // Picsur's multipart field is "image", not the app-wide default "file".
            #expect(String(decoding: req.body ?? Data(), as: UTF8.self).contains(#"name="image""#))
        }
    }

    @Test func directImageURLUsesConfiguredFormat() async throws {
        let result = try await upload(
            config: PicsurConfig(host: "https://pic.bsd-unix.net", imageFormat: "webp"),
            body: success)
        #expect(result.url == "https://pic.bsd-unix.net/i/abc123.webp")
        #expect(result.thumbnailURL == "https://pic.bsd-unix.net/i/abc123.jpg?width=128&shrinkonly=yes")
        #expect(result.deletionURL == "https://pic.bsd-unix.net/api/image/delete/abc123/dk")
    }

    @Test func viewerPageLinkStyle() async throws {
        let result = try await upload(
            config: PicsurConfig(host: "https://pic.bsd-unix.net", linkStyle: .viewerPage),
            body: success)
        #expect(result.url == "https://pic.bsd-unix.net/view/abc123")
    }

    @Test func dropsDeletionURLWhenPicsurWithholdsDeleteKey() async throws {
        let result = try await upload(config: PicsurConfig(host: "https://pic.bsd-unix.net"),
                                      body: #"{"success":true,"data":{"id":"abc123"}}"#)
        #expect(result.url == "https://pic.bsd-unix.net/i/abc123.png")
        #expect(result.deletionURL == nil)
    }

    @Test func rejectsResponseWithoutAnID() async throws {
        // The id token cannot be extracted from an error body, which the engine
        // now reports directly rather than leaving to the empty-URL guard.
        await #expect(throws: UploadError.self) {
            try await upload(config: PicsurConfig(host: "https://pic.bsd-unix.net"),
                             body: #"{"success":false,"data":{"message":"nope"}}"#)
        }
    }

    @Test func surfacesHTTPFailure() async throws {
        let http = FakeHTTP(response: HTTPResponse(status: 401, headers: [:], body: Data("no".utf8)),
                            capture: { _ in })
        let up = PicsurUploader(config: PicsurConfig(host: "https://pic.bsd-unix.net"),
                                secret: PicsurSecret(apiKey: "BAD"), http: http)
        await #expect(throws: UploadError.http(status: 401, body: "no")) {
            try await up.upload(FilePart(fieldName: "file", filename: "a.png",
                                         mimeType: "image/png", data: Data([9])))
        }
    }
}
