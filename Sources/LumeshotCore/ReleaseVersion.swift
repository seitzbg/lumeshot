import Foundation

/// A dotted release version, parsed either from a git tag (`v0.1.8`) or from the
/// bundle's `CFBundleShortVersionString` (`0.1.8`).
///
/// Comparison is numeric per component, not lexicographic, so 0.1.10 is newer than
/// 0.1.9 — the case a string compare gets wrong. Missing trailing components read as
/// zero, so `0.2` and `0.2.0` are the same version.
public struct ReleaseVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    /// Fails on anything that is not a dotted run of non-negative integers. That
    /// deliberately includes an unsubstituted `@VERSION@` and the `Development`
    /// placeholder the app shows when it has no bundle version, so a dev build can
    /// never be told it is out of date.
    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        var parsed: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            parsed.append(value)
        }
        components = parsed
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = Swift.max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let l = index < lhs.components.count ? lhs.components[index] : 0
            let r = index < rhs.components.count ? rhs.components[index] : 0
            if l != r { return l < r }
        }
        return false
    }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
