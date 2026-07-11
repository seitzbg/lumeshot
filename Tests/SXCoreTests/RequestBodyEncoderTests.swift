import Foundation
import Testing
@testable import SXCore

@Suite struct RequestBodyEncoderTests {
    private func str(_ data: Data?) -> String { String(data: data ?? Data(), encoding: .utf8) ?? "" }

    @Test func multipartEncodesFieldsAndFileWithBoundary() {
        let file = FilePart(fieldName: "file", filename: "a.png", mimeType: "image/png",
                            data: Data([0xDE, 0xAD]))
        let (body, ct) = RequestBodyEncoder.encode(
            .multipart(fields: [("k", "v")], file: file), boundary: "BND")
        #expect(ct == "multipart/form-data; boundary=BND")
        let s = str(body)
        #expect(s.contains("--BND\r\nContent-Disposition: form-data; name=\"k\"\r\n\r\nv\r\n"))
        #expect(s.contains(
            "--BND\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.png\"\r\n"
            + "Content-Type: image/png\r\n\r\n"))
        #expect(s.hasSuffix("--BND--\r\n"))
    }

    @Test func formURLEncodedEscapesReservedCharacters() {
        let (body, ct) = RequestBodyEncoder.encode(
            .formURLEncoded([("a b", "c&d"), ("x", "y")]), boundary: "BND")
        #expect(ct == "application/x-www-form-urlencoded")
        #expect(str(body) == "a%20b=c%26d&x=y")
    }

    @Test func jsonPassesThroughWithContentType() {
        let payload = Data(#"{"z":1}"#.utf8)
        let (body, ct) = RequestBodyEncoder.encode(.json(payload), boundary: "BND")
        #expect(ct == "application/json")
        #expect(body == payload)
    }

    @Test func binarySetsFileMimeAndRawBytes() {
        let file = FilePart(fieldName: "", filename: "a.png", mimeType: "image/png",
                            data: Data([1, 2, 3]))
        let (body, ct) = RequestBodyEncoder.encode(.binary(file), boundary: "BND")
        #expect(ct == "image/png")
        #expect(body == Data([1, 2, 3]))
    }

    @Test func noneYieldsNilBody() {
        let (body, ct) = RequestBodyEncoder.encode(.none, boundary: "BND")
        #expect(body == nil)
        #expect(ct == nil)
    }
}
