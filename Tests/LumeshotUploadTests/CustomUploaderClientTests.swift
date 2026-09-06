import Foundation
import Testing
@testable import LumeshotUpload
@testable import LumeshotCore

struct FakeHTTP: HTTPClient {
    let response: HTTPResponse
    let capture: @Sendable (PreparedRequest) -> Void
    func send(_ request: PreparedRequest) async throws -> HTTPResponse {
        capture(request); return response
    }
}

private let png = FilePart(fieldName: "file", filename: "s.png",
                           mimeType: "image/png", data: Data([1, 2]))

@Suite struct CustomUploaderClientTests {
    @Test func uploadsAndParsesURL() async throws {
        var config = CustomUploaderConfig(requestURL: "https://up/api")
        config.fileFormName = "file"
        config.url = "{json:link}"
        let http = FakeHTTP(
            response: HTTPResponse(status: 200, headers: [:],
                                   body: Data(#"{"link":"https://i/x"}"#.utf8)),
            capture: { req in
                #expect(req.url == "https://up/api")
                #expect(req.method == .post)
            })
        let client = CustomUploaderClient(config: config, http: http,
                                          boundaryProvider: { "BND" })
        let result = try await client.upload(png)
        #expect(result.url == "https://i/x")
    }

    @Test func httpErrorPropagates() async {
        var config = CustomUploaderConfig(requestURL: "https://up")
        config.url = "{response}"
        let http = FakeHTTP(response: HTTPResponse(status: 403, headers: [:],
                                                   body: Data("nope".utf8)),
                            capture: { _ in })
        let client = CustomUploaderClient(config: config, http: http, boundaryProvider: { "BND" })
        await #expect(throws: UploadError.self) { _ = try await client.upload(png) }
    }
}

@Suite struct StagedFileBodyTests {
    private func tempFile(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        try bytes.write(to: url)
        return url
    }

    private func config() -> CustomUploaderConfig {
        var c = CustomUploaderConfig(requestURL: "https://up/api")
        c.body = .multipartFormData
        c.fileFormName = "image"
        c.arguments = ["album": "shots"]
        c.url = "{json:link}"
        return c
    }

    /// A file-backed multipart upload must be streamed from a staged body on
    /// disk, and that body must be byte-identical to the in-memory encoding.
    @Test func aFileBackedPartIsStagedToDiskWithTheSameBytes() async throws {
        let payload = Data(repeating: 0x7F, count: 200_000)
        let source = try tempFile(payload)
        defer { try? FileManager.default.removeItem(at: source) }

        let captured = CapturedRequest()
        let http = FakeHTTP(
            response: HTTPResponse(status: 200, headers: [:],
                                   body: Data(#"{"link":"https://x/y"}"#.utf8)),
            capture: { req in captured.record(req) })

        let part = try FilePart.file(fieldName: "file", filename: "clip.mp4",
                                     mimeType: "video/mp4", url: source)
        _ = try await CustomUploaderClient(config: config(), http: http,
                                           boundaryProvider: { "B" }).upload(part)

        let request = try #require(captured.request)
        #expect(request.body == nil)                 // not buffered
        let stagedBytes = try #require(captured.stagedBytes)

        let (expected, _) = RequestBodyEncoder.encode(
            .multipart(fields: [("album", "shots")],
                       file: FilePart(fieldName: "image", filename: "clip.mp4",
                                      mimeType: "video/mp4", data: payload)),
            boundary: "B")
        #expect(stagedBytes == expected)
    }

    /// The staged file is temporary — it must not outlive the upload.
    @Test func theStagedBodyIsCleanedUp() async throws {
        let source = try tempFile(Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: source) }
        let captured = CapturedRequest()
        let http = FakeHTTP(
            response: HTTPResponse(status: 200, headers: [:],
                                   body: Data(#"{"link":"https://x/y"}"#.utf8)),
            capture: { req in captured.record(req) })
        let part = try FilePart.file(fieldName: "file", filename: "c.mp4",
                                     mimeType: "video/mp4", url: source)
        _ = try await CustomUploaderClient(config: config(), http: http,
                                           boundaryProvider: { "B" }).upload(part)
        let staged = try #require(captured.request?.bodyFileURL)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    /// A small, data-backed capture keeps the cheap in-memory path.
    @Test func aDataBackedPartIsStillSentInline() async throws {
        let captured = CapturedRequest()
        let http = FakeHTTP(
            response: HTTPResponse(status: 200, headers: [:],
                                   body: Data(#"{"link":"https://x/y"}"#.utf8)),
            capture: { req in captured.record(req) })
        _ = try await CustomUploaderClient(config: config(), http: http,
                                           boundaryProvider: { "B" })
            .upload(FilePart(fieldName: "file", filename: "a.png",
                             mimeType: "image/png", data: Data([9])))
        #expect(captured.request?.bodyFileURL == nil)
        #expect(captured.request?.body != nil)
    }
}

/// Grabs the request *and* the staged body's bytes while the temp file is still
/// alive — the client deletes it as soon as `upload` returns.
private final class CapturedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: PreparedRequest?
    private var _stagedBytes: Data?

    func record(_ request: PreparedRequest) {
        lock.lock(); defer { lock.unlock() }
        _request = request
        if let url = request.bodyFileURL { _stagedBytes = try? Data(contentsOf: url) }
    }
    var request: PreparedRequest? { lock.lock(); defer { lock.unlock() }; return _request }
    var stagedBytes: Data? { lock.lock(); defer { lock.unlock() }; return _stagedBytes }
}
