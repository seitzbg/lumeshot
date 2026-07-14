import Foundation
import Testing
@testable import LumeshotUpload
@testable import LumeshotCore

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubbedClient() -> URLSessionHTTPClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSessionHTTPClient(session: URLSession(configuration: config))
}

@Suite struct URLSessionHTTPClientTests {
    @Test func sendsBodyAndReturnsStatusHeadersBody() async throws {
        StubURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            let resp = HTTPURLResponse(url: request.url!, statusCode: 201,
                                       httpVersion: nil,
                                       headerFields: ["X-Test": "yes"])!
            return (resp, Data(#"{"ok":true}"#.utf8))
        }
        let req = PreparedRequest(method: .post, url: "https://example.com/up",
                                  headers: ["Authorization": "Bearer k"],
                                  body: Data("hi".utf8), contentType: "text/plain")
        let resp = try await stubbedClient().send(req)
        #expect(resp.status == 201)
        #expect(resp.headers["X-Test"] == "yes")
        #expect(String(data: resp.body, encoding: .utf8) == #"{"ok":true}"#)
    }

    @Test func invalidURLThrowsTransport() async {
        let req = PreparedRequest(method: .get, url: "http://a b c")   // space = invalid
        await #expect(throws: UploadError.self) {
            _ = try await stubbedClient().send(req)
        }
    }
}
