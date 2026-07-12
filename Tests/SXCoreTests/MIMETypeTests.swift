import Testing
@testable import SXCore

@Suite struct MIMETypeTests {
    @Test func mapsKnownExtensions() {
        #expect(MIMEType.forExtension("png") == "image/png")
        #expect(MIMEType.forExtension("PNG") == "image/png")
        #expect(MIMEType.forExtension("gif") == "image/gif")
        #expect(MIMEType.forExtension("mp4") == "video/mp4")
    }

    @Test func unknownExtensionFallsBackToOctetStream() {
        #expect(MIMEType.forExtension("xyz") == "application/octet-stream")
        #expect(MIMEType.forExtension("") == "application/octet-stream")
    }
}
