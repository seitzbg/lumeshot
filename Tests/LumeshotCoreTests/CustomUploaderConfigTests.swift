import Foundation
import Testing
@testable import LumeshotCore

private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "sxcu",
                               subdirectory: "Fixtures")!
    return try Data(contentsOf: url)
}

@Suite struct CustomUploaderConfigTests {
    @Test func parsesImgurFixture() throws {
        let c = try CustomUploaderConfig.parse(fixture("imgur"))
        #expect(c.name == "Imgur (anonymous)")
        #expect(c.requestMethod == .post)
        #expect(c.requestURL == "https://api.imgur.com/3/image")
        #expect(c.headers["Authorization"] == "Client-ID abc123")
        #expect(c.body == .multipartFormData)
        #expect(c.fileFormName == "image")
        #expect(c.url == "{json:data.link}")
        #expect(c.deletionURL == "https://imgur.com/delete/{json:data.deletehash}")
    }

    @Test func parsesGenericFixtureWithArgumentsAndRegex() throws {
        let c = try CustomUploaderConfig.parse(fixture("generic-multipart"))
        #expect(c.arguments["album"] == "screenshots")
        #expect(c.fileFormName == "file")
        #expect(c.regexList == ["https://cdn\\.example\\.com/(\\w+)"])
        #expect(c.url == "{regex:1}")
        #expect(c.thumbnailURL == "{regex:1|1}.thumb")
    }

    @Test func defaultsMethodPostAndBodyMultipart() throws {
        let c = try CustomUploaderConfig.parse(Data(#"{"RequestURL":"https://x"}"#.utf8))
        #expect(c.requestMethod == .post)
        #expect(c.body == .multipartFormData)
    }

    @Test func malformedJSONThrows() {
        #expect(throws: UploadError.self) {
            _ = try CustomUploaderConfig.parse(Data("not json".utf8))
        }
    }

    @Test func xmlBodyIsUnsupported() {
        let json = Data(#"{"RequestURL":"https://x","Body":"XML"}"#.utf8)
        #expect(throws: UploadError.self) {
            _ = try CustomUploaderConfig.parse(json)
        }
    }
}
