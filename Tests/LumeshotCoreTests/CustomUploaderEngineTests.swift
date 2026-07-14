import Foundation
import Testing
@testable import LumeshotCore

// NOTE: brief specified `Data([0xAB])`, but a lone 0xAB is an invalid standalone
// UTF-8 byte (a continuation byte with no lead byte). Embedded in the multipart
// body it makes `String(data:encoding:.utf8)` return nil for the WHOLE buffer,
// which breaks prepareBuildsMultipartWithFileFormNameAndArguments's `.contains`
// assertions regardless of implementation correctness (verified via
// `swift -e 'print(String(data: Data([0x41,0x42,0xAB,0x43]), encoding: .utf8) ?? "NIL")'`
// -> NIL). Using the valid 2-byte UTF-8 encoding of "«" (U+00AB) keeps the same
// "AB" flavor while remaining decodable.
private let png = FilePart(fieldName: "IGNORED", filename: "shot.png",
                           mimeType: "image/png", data: Data([0xC2, 0xAB]))

@Suite struct CustomUploaderEngineTests {
    @Test func prepareBuildsMultipartWithFileFormNameAndArguments() throws {
        var config = CustomUploaderConfig(requestURL: "https://up/api")
        config.body = .multipartFormData
        config.fileFormName = "file"
        config.arguments = ["album": "shots"]
        config.headers = ["X-Auth": "k"]
        let req = try CustomUploaderEngine.prepare(config: config, file: png, boundary: "BND")
        #expect(req.method == .post)
        #expect(req.url == "https://up/api")
        #expect(req.headers["X-Auth"] == "k")
        let s = String(data: req.body ?? Data(), encoding: .utf8) ?? ""
        #expect(s.contains("name=\"album\"\r\n\r\nshots\r\n"))
        #expect(s.contains("name=\"file\"; filename=\"shot.png\""))
        #expect(req.contentType == "multipart/form-data; boundary=BND")
    }

    @Test func prepareAppendsParametersAsQuery() throws {
        var config = CustomUploaderConfig(requestURL: "https://up/api")
        config.parameters = ["key": "v1"]
        let req = try CustomUploaderEngine.prepare(config: config, file: png, boundary: "BND")
        #expect(req.url == "https://up/api?key=v1")
    }

    @Test func multipartDefaultAttachesFileWithDefaultFieldName() throws {
        // The common .sxcu case: Body=MultipartFormData (default) and no FileFormName.
        // The captured file must still be in the body, named "file".
        let config = CustomUploaderConfig(requestURL: "https://up/api")   // no fileFormName
        let req = try CustomUploaderEngine.prepare(config: config, file: png, boundary: "BND")
        let s = String(data: req.body ?? Data(), encoding: .utf8) ?? ""
        #expect(s.contains("name=\"file\"; filename=\"shot.png\""))
    }

    @Test func prepareBinaryBodyUsesRawFileBytes() throws {
        var config = CustomUploaderConfig(requestURL: "https://up/bin")
        config.body = .binary
        let req = try CustomUploaderEngine.prepare(config: config, file: png, boundary: "BND")
        #expect(req.body == png.data)
        #expect(req.contentType == "image/png")
    }

    @Test func parseResultResolvesURLFromJSON() throws {
        var config = CustomUploaderConfig(requestURL: "https://up")
        config.url = "{json:data.link}"
        config.deletionURL = "https://d/{json:data.hash}"
        let body = Data(#"{"data":{"link":"https://i/x.png","hash":"h9"}}"#.utf8)
        let result = try CustomUploaderEngine.parseResult(
            config: config, status: 200, body: body, headers: [:])
        #expect(result.url == "https://i/x.png")
        #expect(result.deletionURL == "https://d/h9")
    }

    @Test func parseResultThrowsOnHTTPError() {
        var config = CustomUploaderConfig(requestURL: "https://up")
        config.url = "{response}"
        #expect(throws: UploadError.self) {
            _ = try CustomUploaderEngine.parseResult(
                config: config, status: 500, body: Data("boom".utf8), headers: [:])
        }
    }

    @Test func parseResultThrowsWhenResolvedURLEmpty() {
        var config = CustomUploaderConfig(requestURL: "https://up")
        config.url = "{json:missing}"
        #expect(throws: UploadError.self) {
            _ = try CustomUploaderEngine.parseResult(
                config: config, status: 200, body: Data("{}".utf8), headers: [:])
        }
    }

    @Test func prepareThrowsWhenRequestURLEmpty() {
        let config = CustomUploaderConfig(requestURL: "")
        #expect(throws: UploadError.self) {
            _ = try CustomUploaderEngine.prepare(config: config, file: png, boundary: "BND")
        }
    }
}
