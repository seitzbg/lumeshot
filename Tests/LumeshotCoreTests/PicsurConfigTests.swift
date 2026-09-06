import Foundation
import Testing
@testable import LumeshotCore

@Suite struct PicsurConfigTests {
    @Test(arguments: [
        ("pic.example.net", "https://pic.example.net"),
        ("https://pic.example.net/", "https://pic.example.net"),
        ("https://pic.example.net///", "https://pic.example.net"),
        ("  http://box.lan:8080  ", "http://box.lan:8080"),
        ("HTTPS://Pic.Example.Net", "HTTPS://Pic.Example.Net"),
        ("", ""),
    ])
    func normalizesHost(raw: String, expected: String) {
        #expect(PicsurConfig.normalizeHost(raw) == expected)
    }

    @Test(arguments: [(".PNG", "png"), ("jpg", "jpg"), ("", "png"), ("  .WebP ", "webp")])
    func normalizesFormat(raw: String, expected: String) {
        #expect(PicsurConfig.normalizeFormat(raw) == expected)
    }

    @Test func urlsMatchPicsurOwnShareXGenerator() {
        let c = PicsurConfig(host: "pic.example.net/", imageFormat: ".JPG")
        #expect(c.uploadURL == "https://pic.example.net/api/image/upload")
        #expect(c.url(id: "abc") == "https://pic.example.net/i/abc.jpg")
        #expect(c.thumbnailURL(id: "abc")
                == "https://pic.example.net/i/abc.jpg?width=128&shrinkonly=yes")
        #expect(c.deletionURL(id: "abc", deleteKey: "dk")
                == "https://pic.example.net/api/image/delete/abc/dk")
    }

    @Test func roundTripsThroughCodable() throws {
        let c = PicsurConfig(host: "pic.example.net", imageFormat: "webp", linkStyle: .viewerPage)
        let decoded = try JSONDecoder().decode(PicsurConfig.self, from: JSONEncoder().encode(c))
        #expect(decoded == c)
    }

    @Test func destinationRoundTripsThroughSettings() throws {
        let dest = UploadDestination(id: "d1", name: "Picsur", kind: .picsur,
                                     picsurConfig: PicsurConfig(host: "pic.example.net"))
        let settings = UploadSettings(uploadAfterCapture: true, activeDestinationID: "d1",
                                      destinations: [dest])
        let decoded = try JSONDecoder().decode(UploadSettings.self,
                                               from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.activeDestination?.kind == .picsur)
    }
}
