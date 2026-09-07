import Foundation

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(current: ReleaseVersion)
    case updateAvailable(latest: ReleaseVersion, releasePage: URL)
    /// The running build has no comparable version — a local `scripts/bundle.sh`
    /// build, or an unsubstituted `@VERSION@`. Never reported as out of date.
    case unknownCurrentVersion
}

public enum UpdateCheckError: Error, Equatable, Sendable {
    case malformedResponse
    case unusableTag(String)
}

/// Decides whether a newer Lumeshot has been published, given the running version
/// and GitHub's `releases/latest` payload.
///
/// The decision is a pure function of its two inputs so it can be tested without a
/// network: the app fetches the bytes and calls `result(currentVersion:latestReleaseJSON:)`.
/// Nothing here downloads or installs — this only tells the user a release exists.
public enum UpdateCheck {
    public static let latestReleaseAPI = URL(string:
        "https://api.github.com/repos/seitzbg/lumeshot/releases/latest")!

    private struct Payload: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
    }

    public static func result(currentVersion: String,
                              latestReleaseJSON: Data) throws -> UpdateCheckResult {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: latestReleaseJSON),
              let page = URL(string: payload.html_url) else {
            throw UpdateCheckError.malformedResponse
        }
        guard let latest = ReleaseVersion(payload.tag_name) else {
            throw UpdateCheckError.unusableTag(payload.tag_name)
        }
        // A draft or pre-release is not something to point users at. GitHub's
        // `releases/latest` already excludes both, so this only matters if the
        // endpoint or the repo's release process changes.
        if payload.draft == true || payload.prerelease == true {
            guard let current = ReleaseVersion(currentVersion) else { return .unknownCurrentVersion }
            return .upToDate(current: current)
        }
        guard let current = ReleaseVersion(currentVersion) else { return .unknownCurrentVersion }
        return latest > current
            ? .updateAvailable(latest: latest, releasePage: page)
            : .upToDate(current: current)
    }
}
