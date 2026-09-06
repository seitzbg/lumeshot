import Foundation
import LumeshotCore

/// Connect, auth, write `data` to `remotePath`, close — all within one call.
/// The real implementation (`CitadelSFTPTransport`) is Mac-smoke-only; `SFTPUploader`
/// is unit-tested against a fake conforming type.
public protocol SFTPTransport: Sendable {
    /// - Parameters:
    ///   - knownHostKey: the pinned fingerprint, or nil to trust on first use.
    ///   - rememberHostKey: called with the presented fingerprint when it is
    ///     learned for the first time, so the caller can persist the pin.
    func upload(_ data: Data, to remotePath: String, host: String, port: Int,
               username: String, secret: SFTPSecret,
               knownHostKey: String?,
               rememberHostKey: @escaping @Sendable (String) -> Void) async throws
}
