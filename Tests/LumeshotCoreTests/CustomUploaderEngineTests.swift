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
        #expect(req.body == (try png.readData()))
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

@Suite struct ResponseOnlyUploaderTests {
    private func parse(url: String?, body: String) throws -> UploadResult {
        var config = CustomUploaderConfig(requestURL: "https://up/api")
        config.url = url
        return try CustomUploaderEngine.parseResult(config: config, status: 200,
                                                    body: Data(body.utf8), headers: [:])
    }

    @Test func absentURLTemplateUsesTheResponseBody() throws {
        // Lumeshot permits an empty URL: the body is already the link.
        #expect(try parse(url: nil, body: "https://i.example.net/a.png").url
                == "https://i.example.net/a.png")
    }

    @Test func emptyURLTemplateUsesTheResponseBody() throws {
        #expect(try parse(url: "", body: "  https://i.example.net/b.png\n ").url
                == "https://i.example.net/b.png")
    }

    @Test func anExplicitTemplateStillWins() throws {
        #expect(try parse(url: "{json:data.link}",
                          body: #"{"data":{"link":"https://x/y.png"}}"#).url == "https://x/y.png")
    }

    @Test(arguments: ["", "   ", "not a url", "<html>error</html>", "ftp://h/a.png", "/relative"])
    func aBodyThatIsNotAnHTTPURLIsRejected(body: String) {
        // Better to fail loudly than copy an HTML error page to the clipboard.
        #expect(throws: UploadError.emptyURL) { try parse(url: nil, body: body) }
    }

    /// An HTTP 200 carrying an error body used to assemble the literal parts of
    /// the template into a plausible URL — "https://example.com/i/.png" — which
    /// was recorded as a success and put on the clipboard in place of the image.
    @Test func aTemplateTokenMissingFromTheResponseFailsTheUpload() throws {
        var config = CustomUploaderConfig(requestURL: "https://example.com/upload")
        config.url = "https://example.com/i/{json:data.id}.png"
        #expect(throws: UploadError.self) {
            try CustomUploaderEngine.parseResult(
                config: config, status: 200,
                body: Data(#"{"success":false,"error":"quota exceeded"}"#.utf8), headers: [:])
        }
    }

    /// An explicit template that resolves to a non-web value — a `file:` URL, a
    /// custom app scheme, or arbitrary text — must not be reported as a
    /// successful upload. It would replace the screenshot on the clipboard and,
    /// opened from History, launch a local app or file instead of a web link.
    @Test(arguments: ["file:///Applications/Calculator.app", "myapp://open", "not a url"])
    func anExplicitTemplateResolvingToANonWebValueIsRejected(link: String) {
        var config = CustomUploaderConfig(requestURL: "https://up/api")
        config.url = "{json:data.link}"
        let body = Data("{\"data\":{\"link\":\"\(link)\"}}".utf8)
        #expect(throws: UploadError.self) {
            _ = try CustomUploaderEngine.parseResult(config: config, status: 200, body: body, headers: [:])
        }
    }

    /// A required token that is present but empty ("") must not concatenate with
    /// the template's literals into a plausible-but-broken link. This is distinct
    /// from a missing token (the field is present, its value is empty) and from a
    /// non-web URL (the assembled string is a syntactically valid https URL, so
    /// validating the final URL alone would not catch it).
    @Test func aRequiredEmptyIdentifierIsNotASuccessfulURL() {
        var config = CustomUploaderConfig(requestURL: "https://example.invalid/upload")
        config.url = "https://example.invalid/i/{json:data.id}.png"
        #expect(throws: UploadError.self) {
            _ = try CustomUploaderEngine.parseResult(
                config: config, status: 200,
                body: Data(#"{"data":{"id":""}}"#.utf8), headers: [:])
        }
    }

    /// A thumbnail or deletion link that cannot be extracted is dropped, not
    /// fatal: the upload itself succeeded.
    @Test func optionalLinksAreDroppedWhenTheirTokensAreMissing() throws {
        var config = CustomUploaderConfig(requestURL: "https://example.com/upload")
        config.url = "{json:link}"
        config.deletionURL = "https://example.com/d/{json:delete_key}"
        let result = try CustomUploaderEngine.parseResult(
            config: config, status: 200,
            body: Data(#"{"link":"https://example.com/i/abc.png"}"#.utf8), headers: [:])
        #expect(result.url == "https://example.com/i/abc.png")
        #expect(result.deletionURL == nil)
    }
}
