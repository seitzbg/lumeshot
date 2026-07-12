import Foundation
import Testing
@testable import SXUpload
@testable import SXCore

private struct CapturingHTTP: HTTPClient {
    let response: HTTPResponse
    let capture: @Sendable (PreparedRequest) -> Void
    func send(_ request: PreparedRequest) async throws -> HTTPResponse {
        capture(request); return response
    }
}

@Suite struct UploaderMimeTests {
    @Test func customUploaderMultipartCarriesTheFilePartMime() async throws {
        var config = CustomUploaderConfig(requestURL: "https://up/api")
        config.fileFormName = "file"
        config.url = "{json:link}"
        let http = CapturingHTTP(
            response: HTTPResponse(status: 200, headers: [:], body: Data(#"{"link":"https://i/x"}"#.utf8)),
            capture: { req in
                let text = String(decoding: req.body ?? Data(), as: UTF8.self)
                #expect(text.contains("Content-Type: video/mp4"))
                #expect(text.contains(#"filename="clip.mp4""#))
            })
        let client = CustomUploaderClient(config: config, http: http, boundaryProvider: { "BOUND" })

        let file = FilePart(fieldName: "file", filename: "clip.mp4",
                            mimeType: "video/mp4", data: Data([0, 1, 2, 3]))
        _ = try await client.upload(file)
    }
}
