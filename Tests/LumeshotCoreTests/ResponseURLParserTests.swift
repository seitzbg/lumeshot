import Foundation
import Testing
@testable import LumeshotCore

private func ctx(body: String = "", headers: [String: String] = [:],
                 regex: [String] = []) -> ResponseContext {
    ResponseContext(body: body, headers: headers, regexList: regex)
}

@Suite struct ResponseURLParserTests {
    @Test func responseTokenReturnsWholeBody() {
        let out = ResponseURLParser.resolve("{response}", context: ctx(body: "hello"))
        #expect(out == "hello")
    }

    @Test func jsonDottedPath() {
        let body = #"{"data":{"link":"https://i/x.png"}}"#
        let out = ResponseURLParser.resolve("{json:data.link}", context: ctx(body: body))
        #expect(out == "https://i/x.png")
    }

    @Test func jsonArrayIndex() {
        let body = #"{"files":[{"url":"a"},{"url":"b"}]}"#
        let out = ResponseURLParser.resolve("{json:files[1].url}", context: ctx(body: body))
        #expect(out == "b")
    }

    @Test func regexWholeMatchAndGroup() {
        let body = "id=https://cdn/abc123 end"
        let c = ctx(body: body, regex: ["https://cdn/(\\w+)"])
        #expect(ResponseURLParser.resolve("{regex:1}", context: c) == "https://cdn/abc123")
        #expect(ResponseURLParser.resolve("{regex:1|1}", context: c) == "abc123")
    }

    @Test func regexOutOfRangeGroupResolvesToNothing() {
        let c = ctx(body: "https://cdn/abc123", regex: ["https://cdn/(\\w+)"])
        // Malformed / adversarial group indices from community .sxcu files must
        // report failure, never crash range(at:) and never quietly yield "".
        #expect(ResponseURLParser.resolve("{regex:1|-1}", context: c) == nil)
        #expect(ResponseURLParser.resolve("{regex:1|9}", context: c) == nil)
    }

    @Test func headerLookupIsCaseInsensitive() {
        let c = ctx(headers: ["Location": "https://x/y"])
        #expect(ResponseURLParser.resolve("{header:location}", context: c) == "https://x/y")
    }

    @Test func literalTextAndSurroundingChars() {
        let body = #"{"hash":"h1"}"#
        let out = ResponseURLParser.resolve("https://site/{json:hash}/view", context: ctx(body: body))
        #expect(out == "https://site/h1/view")
    }

    /// A token that cannot be extracted fails the whole template. It used to
    /// become "", so a template with literal text around it still resolved to a
    /// plausible string — "https://host/i/.png" — and was reported as a
    /// successful upload.
    @Test func unknownOrMissingTokenFailsTheWholeTemplate() {
        #expect(ResponseURLParser.resolve("{json:nope}", context: ctx(body: "{}")) == nil)
        #expect(ResponseURLParser.resolve("a{bogus}b", context: ctx()) == nil)
        #expect(ResponseURLParser.resolve("https://host/i/{json:data.id}.png",
                                          context: ctx(body: #"{"error":"quota"}"#)) == nil)
    }

    /// Present-but-empty is a real answer and stays distinct from "not found";
    /// likewise an empty body for {response}.
    @Test func anEmptyValueThatIsActuallyPresentStillResolves() {
        #expect(ResponseURLParser.resolve("{json:id}", context: ctx(body: #"{"id":""}"#)) == "")
        #expect(ResponseURLParser.resolve("{response}", context: ctx(body: "")) == "")
    }
}
