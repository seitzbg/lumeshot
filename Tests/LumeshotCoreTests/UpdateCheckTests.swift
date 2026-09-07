import Testing
import Foundation
@testable import LumeshotCore

@Suite struct ReleaseVersionTests {
    @Test func parsesATagAndABundleVersionTheSameWay() {
        #expect(ReleaseVersion("v0.1.8") == ReleaseVersion("0.1.8"))
        #expect(ReleaseVersion("V2.0.0")?.description == "2.0.0")
    }

    /// The case a string compare gets wrong.
    @Test func comparesComponentsNumericallyNotLexicographically() throws {
        let nine = try #require(ReleaseVersion("0.1.9"))
        let ten = try #require(ReleaseVersion("0.1.10"))
        #expect(ten > nine)
        #expect("0.1.10" < "0.1.9")   // documents why this type exists
    }

    @Test func missingTrailingComponentsReadAsZero() throws {
        #expect(try #require(ReleaseVersion("0.2")) == #require(ReleaseVersion("0.2.0")))
        #expect(try #require(ReleaseVersion("1")) < #require(ReleaseVersion("1.0.1")))
    }

    @Test func ordersAcrossEveryComponent() throws {
        let ordered = try ["0.9.9", "1.0.0", "1.0.1", "1.1.0", "2.0.0"]
            .map { try #require(ReleaseVersion($0)) }
        #expect(ordered == ordered.sorted())
    }

    @Test func rejectsAnythingThatIsNotADottedNumber() {
        for bad in ["", "v", "@VERSION@", "Development", "1.2.x", "1..2", "1.2.", "-1.0", "1 .2"] {
            #expect(ReleaseVersion(bad) == nil, "expected \(bad) to be rejected")
        }
    }
}

@Suite struct UpdateCheckTests {
    private func payload(tag: String,
                         url: String = "https://github.com/seitzbg/lumeshot/releases/tag/v9.9.9",
                         draft: Bool = false, prerelease: Bool = false) -> Data {
        Data("""
        {"tag_name":"\(tag)","html_url":"\(url)","draft":\(draft),"prerelease":\(prerelease)}
        """.utf8)
    }

    @Test func reportsAnUpdateWhenThePublishedTagIsNewer() throws {
        let result = try UpdateCheck.result(currentVersion: "0.1.8",
                                            latestReleaseJSON: payload(tag: "v0.2.0"))
        guard case .updateAvailable(let latest, let page) = result else {
            Issue.record("expected updateAvailable, got \(result)"); return
        }
        #expect(latest.description == "0.2.0")
        #expect(page.host == "github.com")
    }

    @Test func reportsUpToDateWhenTheTagMatches() throws {
        let result = try UpdateCheck.result(currentVersion: "0.1.8",
                                            latestReleaseJSON: payload(tag: "v0.1.8"))
        #expect(result == .upToDate(current: ReleaseVersion("0.1.8")!))
    }

    /// Running ahead of the published release (a local build of an unreleased commit)
    /// must not advertise a downgrade.
    @Test func reportsUpToDateWhenRunningAheadOfTheRelease() throws {
        let result = try UpdateCheck.result(currentVersion: "0.2.0",
                                            latestReleaseJSON: payload(tag: "v0.1.8"))
        #expect(result == .upToDate(current: ReleaseVersion("0.2.0")!))
    }

    /// scripts/bundle.sh leaves a dev bundle without a real version; it must never be
    /// told to update.
    @Test func aBuildWithNoUsableVersionIsNeverOutOfDate() throws {
        for current in ["@VERSION@", "Development", ""] {
            let result = try UpdateCheck.result(currentVersion: current,
                                                latestReleaseJSON: payload(tag: "v9.9.9"))
            #expect(result == .unknownCurrentVersion)
        }
    }

    @Test func draftsAndPrereleasesAreNotOffered() throws {
        for json in [payload(tag: "v9.9.9", draft: true), payload(tag: "v9.9.9", prerelease: true)] {
            let result = try UpdateCheck.result(currentVersion: "0.1.8", latestReleaseJSON: json)
            #expect(result == .upToDate(current: ReleaseVersion("0.1.8")!))
        }
    }

    @Test func malformedPayloadsThrowRatherThanGuess() {
        for bad in [Data("not json".utf8), Data("{}".utf8), Data(), Data("[]".utf8)] {
            #expect(throws: UpdateCheckError.self) {
                try UpdateCheck.result(currentVersion: "0.1.8", latestReleaseJSON: bad)
            }
        }
    }

    @Test func aTagThatIsNotAVersionThrows() {
        #expect(throws: UpdateCheckError.unusableTag("nightly")) {
            try UpdateCheck.result(currentVersion: "0.1.8", latestReleaseJSON: payload(tag: "nightly"))
        }
    }
}
