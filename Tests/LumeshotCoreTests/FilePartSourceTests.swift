import Foundation
import Testing
@testable import LumeshotCore

@Suite struct FilePartSourceTests {
    private func tempFile(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
        try bytes.write(to: url)
        return url
    }

    @Test func aDataBackedPartReportsItsOwnBytes() throws {
        let part = FilePart(fieldName: "f", filename: "a.png", mimeType: "image/png",
                            data: Data([1, 2, 3]))
        #expect(part.byteCount == 3)
        #expect(try part.readData() == Data([1, 2, 3]))
    }

    @Test func aFileBackedPartReadsFromDiskAndKnowsItsSize() throws {
        let bytes = Data(repeating: 0xAB, count: 5000)
        let url = try tempFile(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let part = try FilePart.file(fieldName: "f", filename: "a.mp4",
                                     mimeType: "video/mp4", url: url)
        #expect(part.byteCount == 5000)
        #expect(try part.readData() == bytes)
    }

    @Test func aMissingFileThrowsRatherThanUploadingNothing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        #expect(throws: (any Error).self) {
            try FilePart.file(fieldName: "f", filename: "x", mimeType: "video/mp4", url: missing)
        }
    }

    /// The point of the cap: refuse before allocating, not during.
    @Test func anOversizedPartRefusesToMaterialize() {
        let url = URL(fileURLWithPath: "/nonexistent")
        let part = FilePart(fieldName: "f", filename: "huge.mp4", mimeType: "video/mp4",
                            source: .file(url, byteCount: maxUploadBytes + 1))
        #expect(throws: (any Error).self) { try part.readData() }
    }

    @Test func aPartExactlyAtTheLimitIsStillAllowed() throws {
        let bytes = Data([1, 2, 3])
        let url = try tempFile(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        var part = try FilePart.file(fieldName: "f", filename: "a", mimeType: "x", url: url)
        part.source = .file(url, byteCount: maxUploadBytes)
        #expect(throws: Never.self) { try part.readData() }
    }
}

@Suite struct StreamedMultipartTests {
    /// The staged (streamed) body must be byte-identical to the in-memory one,
    /// or a server would see a different request depending on payload size.
    @Test func prologuePlusPayloadPlusEpilogueEqualsTheInMemoryEncoding() throws {
        let payload = Data(repeating: 0x5A, count: 4096)
        let part = FilePart(fieldName: "image", filename: "a.png", mimeType: "image/png",
                            data: payload)
        let fields = [("album", "shots"), ("title", "x")]
        let boundary = "BOUNDARY"

        let (inMemory, contentType) = RequestBodyEncoder.encode(
            .multipart(fields: fields, file: part), boundary: boundary)

        var streamed = RequestBodyEncoder.multipartPrologue(fields: fields, file: part,
                                                            boundary: boundary)
        streamed.append(payload)
        streamed.append(RequestBodyEncoder.multipartEpilogue(boundary: boundary))

        #expect(streamed == inMemory)
        #expect(contentType == RequestBodyEncoder.multipartContentType(boundary: boundary))
    }

    @Test func theEpilogueClosesTheBoundary() {
        let epilogue = String(decoding: RequestBodyEncoder.multipartEpilogue(boundary: "B"),
                              as: UTF8.self)
        #expect(epilogue == "\r\n--B--\r\n")
    }

    @Test func aMultipartBodyWithNoFileStillTerminates() {
        let (body, _) = RequestBodyEncoder.encode(
            .multipart(fields: [("a", "b")], file: nil), boundary: "B")
        #expect(String(decoding: body ?? Data(), as: UTF8.self).hasSuffix("--B--\r\n"))
    }
}
