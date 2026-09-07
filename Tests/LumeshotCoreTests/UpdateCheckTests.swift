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
                         draft: Bool = false, prerelease: Bool = false,
                         assets: [(String, String)] = [
                            ("Lumeshot-9.9.9.dmg", "https://example.com/Lumeshot-9.9.9.dmg"),
                            ("SHA256SUMS.txt", "https://example.com/SHA256SUMS.txt"),
                         ]) -> Data {
        let assetJSON = assets
            .map { "{\"name\":\"\($0.0)\",\"browser_download_url\":\"\($0.1)\"}" }
            .joined(separator: ",")
        return Data("""
        {"tag_name":"\(tag)","html_url":"\(url)","draft":\(draft),"prerelease":\(prerelease),\
        "assets":[\(assetJSON)]}
        """.utf8)
    }

    @Test func reportsAnUpdateWhenThePublishedTagIsNewer() throws {
        let result = try UpdateCheck.result(currentVersion: "0.1.8", isReleaseBuild: true,
                                            latestReleaseJSON: payload(tag: "v0.2.0"))
        guard case .updateAvailable(let latest, let page, let download) = result else {
            Issue.record("expected updateAvailable, got \(result)"); return
        }
        #expect(latest.description == "0.2.0")
        #expect(page.host == "github.com")
        #expect(download?.dmgName == "Lumeshot-9.9.9.dmg")
        #expect(download?.checksumsURL?.lastPathComponent == "SHA256SUMS.txt")
    }

    /// A release with no dmg still reports the update — there is just nothing to
    /// download, so the UI can only offer the release page.
    @Test func anUpdateWithNoDmgHasNoDownload() throws {
        let result = try UpdateCheck.result(currentVersion: "0.1.8", isReleaseBuild: true,
                                            latestReleaseJSON: payload(tag: "v0.2.0", assets: []))
        guard case .updateAvailable(_, _, let download) = result else {
            Issue.record("expected updateAvailable, got \(result)"); return
        }
        #expect(download == nil)
    }

    /// A dmg published without its checksum file: the download is offered as
    /// unverifiable rather than silently trusted.
    @Test func aDmgWithoutChecksumsHasNoChecksumURL() throws {
        let result = try UpdateCheck.result(
            currentVersion: "0.1.8", isReleaseBuild: true,
            latestReleaseJSON: payload(tag: "v0.2.0",
                                       assets: [("Lumeshot-9.9.9.dmg", "https://example.com/x.dmg")]))
        guard case .updateAvailable(_, _, let download) = result else {
            Issue.record("expected updateAvailable, got \(result)"); return
        }
        #expect(download?.dmgName == "Lumeshot-9.9.9.dmg")
        #expect(download?.checksumsURL == nil)
    }

    @Test func reportsUpToDateWhenTheTagMatches() throws {
        let result = try UpdateCheck.result(currentVersion: "0.1.8", isReleaseBuild: true,
                                            latestReleaseJSON: payload(tag: "v0.1.8"))
        #expect(result == .upToDate(current: ReleaseVersion("0.1.8")!))
    }

    /// Running ahead of the published release (a local build of an unreleased commit)
    /// must not advertise a downgrade.
    @Test func reportsUpToDateWhenRunningAheadOfTheRelease() throws {
        let result = try UpdateCheck.result(currentVersion: "0.2.0", isReleaseBuild: true,
                                            latestReleaseJSON: payload(tag: "v0.1.8"))
        #expect(result == .upToDate(current: ReleaseVersion("0.2.0")!))
    }

    /// A version string that cannot be parsed at all — an unsubstituted template, or
    /// the placeholder used when the bundle has no version key.
    @Test func aBuildWithNoUsableVersionIsNeverOutOfDate() throws {
        for current in ["@VERSION@", "Development", ""] {
            let result = try UpdateCheck.result(currentVersion: current, isReleaseBuild: true,
                                                latestReleaseJSON: payload(tag: "v9.9.9"))
            #expect(result == .notAReleaseBuild)
        }
    }

    /// scripts/bundle.sh defaults VERSION to 0.1.0 and stamps it into the plist, so a
    /// local build of newer code parses as a valid *older* release. Only the release
    /// channel can tell the difference, and without it the developer is offered an
    /// "update" that would downgrade them.
    @Test func aDevelopmentBuildStampedWithTheBundleDefaultIsNotOfferedAnUpdate() throws {
        let asRelease = try UpdateCheck.result(currentVersion: "0.1.0", isReleaseBuild: true,
                                               latestReleaseJSON: payload(tag: "v0.1.8"))
        guard case .updateAvailable = asRelease else {
            Issue.record("a real 0.1.0 release should be offered 0.1.8"); return
        }
        // Same version string, development channel: no offer.
        let asDevelopment = try UpdateCheck.result(currentVersion: "0.1.0", isReleaseBuild: false,
                                                   latestReleaseJSON: payload(tag: "v0.1.8"))
        #expect(asDevelopment == .notAReleaseBuild)
    }

    @Test func draftsAndPrereleasesAreNotOffered() throws {
        for json in [payload(tag: "v9.9.9", draft: true), payload(tag: "v9.9.9", prerelease: true)] {
            let result = try UpdateCheck.result(currentVersion: "0.1.8", isReleaseBuild: true,
                                                latestReleaseJSON: json)
            #expect(result == .upToDate(current: ReleaseVersion("0.1.8")!))
        }
    }

    @Test func malformedPayloadsThrowRatherThanGuess() {
        for bad in [Data("not json".utf8), Data("{}".utf8), Data(), Data("[]".utf8)] {
            #expect(throws: UpdateCheckError.self) {
                try UpdateCheck.result(currentVersion: "0.1.8", isReleaseBuild: true,
                                       latestReleaseJSON: bad)
            }
        }
    }

    @Test func aTagThatIsNotAVersionThrows() {
        #expect(throws: UpdateCheckError.unusableTag("nightly")) {
            try UpdateCheck.result(currentVersion: "0.1.8", isReleaseBuild: true,
                                       latestReleaseJSON: payload(tag: "nightly"))
        }
    }
}
