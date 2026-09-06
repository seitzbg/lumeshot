import Foundation

/// Shared, pure path/URL joining for the SFTP and FTP uploaders — one
/// implementation instead of duplicating "trim trailing slash, join with
/// exactly one" in both `SFTPUploader` and `FTPUploader`.
public enum RemotePathURLMapper {
    /// Join a remote directory and filename with exactly one slash.
    public static func remotePath(directory: String, filename: String) -> String {
        let dir = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        return "\(dir)/\(filename)"
    }

    /// publicURLBase + "/" + percent-encoded filename (base trailing slash trimmed).
    ///
    /// The filename is a *path* produced by NameParser, which only sanitizes
    /// "/" and ":" — a `%pn` template routinely yields spaces and can produce
    /// "#", "?" or "%". Concatenating those raw turned the rest of the URL into
    /// a fragment or query, so the copied link did not address the object we
    /// had just uploaded.
    public static func resultURL(publicURLBase: String, filename: String) -> String {
        let base = publicURLBase.hasSuffix("/") ? String(publicURLBase.dropLast()) : publicURLBase
        return "\(base)/\(encodePath(filename))"
    }

    /// Percent-encode one path segment, keeping only RFC 3986 unreserved
    /// characters verbatim. Matches the AWS URI-encoding rule, so S3 and the
    /// SFTP/FTP public URLs agree on how a given filename is spelled.
    public static func encodeSegment(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Encode each "/"-separated segment, preserving the separators.
    public static func encodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { encodeSegment(String($0)) }.joined(separator: "/")
    }
}
