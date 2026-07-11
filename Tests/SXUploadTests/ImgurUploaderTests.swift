import Foundation
import Testing
@testable import SXUpload
@testable import SXCore

@Suite struct ImgurUploaderTests {
    @Test func anonymousUploadParsesLink() async throws {
        let http = FakeHTTP(
            response: HTTPResponse(status: 200, headers: [:],
                body: Data(#"{"data":{"link":"https://i.imgur.com/a.png","deletehash":"dh"}}"#.utf8)),
            capture: { req in
                #expect(req.url == "https://api.imgur.com/3/image")
                #expect(req.headers["Authorization"] == "Client-ID CID")
            })
        let up = ImgurUploader(clientID: "CID", http: http)
        let file = FilePart(fieldName: "image", filename: "a.png",
                            mimeType: "image/png", data: Data([9]))
        let result = try await up.upload(file)
        #expect(result.url == "https://i.imgur.com/a.png")
        #expect(result.deletionURL == "https://imgur.com/delete/dh")
    }
}
