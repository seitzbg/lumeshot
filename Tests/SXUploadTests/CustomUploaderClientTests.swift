import Foundation
import Testing
@testable import SXUpload
@testable import SXCore

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
