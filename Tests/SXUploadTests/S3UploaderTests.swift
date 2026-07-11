import Foundation
import Testing
@testable import SXUpload
import SXCore

private final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    var response: HTTPResponse
    var lastRequest: PreparedRequest?
    init(response: HTTPResponse) { self.response = response }
    func send(_ request: PreparedRequest) async throws -> HTTPResponse {
        lastRequest = request
        return response
    }
}

@Suite struct S3UploaderTests {
    private let creds = SigV4Credentials(accessKeyID: "AK", secretAccessKey: "SK")
    private var config: S3Config {
        S3Config(region: "us-east-1", endpoint: "s3.us-east-1.amazonaws.com",
                 bucket: "shots", objectPrefix: "screens/")
    }
    private func png() -> FilePart {
        FilePart(fieldName: "file", filename: "shot.png", mimeType: "image/png", data: Data([1, 2, 3]))
    }
    private var fixedNow: @Sendable () -> Date { { Date(timeIntervalSince1970: 1_440_938_160) } }

    @Test func successReturnsDerivedResultURL() async throws {
        let mock = MockHTTPClient(response: HTTPResponse(status: 200, headers: [:], body: Data()))
        let uploader = S3Uploader(config: config, credentials: creds, http: mock, now: fixedNow)
        let result = try await uploader.upload(png())
        #expect(result.url == "https://shots.s3.us-east-1.amazonaws.com/screens/shot.png")
        #expect(mock.lastRequest?.method == .put)
        #expect(mock.lastRequest?.headers["Authorization"] != nil)
    }

    @Test func non2xxThrowsHTTPError() async {
        let mock = MockHTTPClient(response: HTTPResponse(status: 403, headers: [:],
                                                         body: Data("AccessDenied".utf8)))
        let uploader = S3Uploader(config: config, credentials: creds, http: mock, now: fixedNow)
        await #expect(throws: UploadError.self) {
            _ = try await uploader.upload(png())
        }
    }
}
