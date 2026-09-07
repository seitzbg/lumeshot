import Foundation
import Testing
@testable import LumeshotApp

struct OpenSourceCreditsTests {
    @Test func bundledCreditsCoverResolvedDependencies() throws {
        let credits = try OpenSourceCredit.load()
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        struct Resolution: Decodable {
            struct Pin: Decodable {
                struct State: Decodable { let version: String }
                let identity: String
                let state: State
            }
            let pins: [Pin]
        }
        let resolved = try JSONDecoder().decode(Resolution.self,
            from: Data(contentsOf: root.appendingPathComponent("Package.resolved")))
        for pin in resolved.pins {
            let credit = try #require(credits.first { $0.id == pin.identity },
                                      "Run python3 scripts/generate-credits.py after dependency changes")
            #expect(credit.version == pin.state.version)
        }
        #expect(credits.contains { $0.id == "libcurl" })
        #expect(credits.contains { $0.id == "sqlite" })
        #expect(credits.contains { $0.id == "boringssl" })
        #expect(Set(credits.map(\.id)).count == credits.count)
        for credit in credits {
            #expect(!credit.notice.isEmpty)
            #expect(credit.url.scheme == "https")
        }
    }
}
