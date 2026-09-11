import Foundation

/// Validation for a public web link.
///
/// One rule, two boundaries: a value is only usable as an uploaded-image link
/// if it is an absolute `http`/`https` URL with a host. It gates what may be
/// published as an upload's result — so a 200 response carrying HTML, arbitrary
/// text, a `file:` URL or a custom app scheme is never reported as success and
/// copied to the clipboard — and it gates what the app will hand to the system
/// opener, so a link stored in an older history row (recorded before that
/// check) still cannot launch a local file or another app's URL handler when
/// clicked.
public enum WebLink {
    /// The absolute http(s) URL `candidate` denotes, or nil. Leading and
    /// trailing whitespace is tolerated (a response body often has a trailing
    /// newline); the scheme must be http or https and a host must be present.
    public static func openable(_ candidate: String) -> URL? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty,
              let url = comps.url
        else { return nil }
        return url
    }

    /// Whether `candidate` is a usable public web link.
    public static func isOpenable(_ candidate: String) -> Bool {
        openable(candidate) != nil
    }
}
