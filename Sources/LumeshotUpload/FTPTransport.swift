import Foundation

/// Connect, auth, write `data` to `url`, close — all within one call. The real
/// implementation (`CurlFTPTransport`) is Mac-smoke-only; `FTPUploader` is
/// unit-tested against a fake conforming type.
public protocol FTPTransport: Sendable {
    func upload(_ data: Data, to url: String, username: String, password: String,
               useTLS: Bool) async throws
}
