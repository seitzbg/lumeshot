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

    /// publicURLBase + "/" + filename (base trailing slash trimmed).
    public static func resultURL(publicURLBase: String, filename: String) -> String {
        let base = publicURLBase.hasSuffix("/") ? String(publicURLBase.dropLast()) : publicURLBase
        return "\(base)/\(filename)"
    }
}
