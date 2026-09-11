import Foundation
import LumeshotCore

/// Connect, auth, write `data` to `remotePath`, close — all within one call.
/// The real implementation (`CitadelSFTPTransport`) is Mac-smoke-only; `SFTPUploader`
/// is unit-tested against a fake conforming type.
public protocol SFTPTransport: Sendable {
    /// - Parameters:
    ///   - knownHostKey: the pinned fingerprint, or nil to trust on first use.
    ///   - rememberHostKey: called with the presented fingerprint on first use to
    ///     persist the pin. It returns whether the connection may proceed: the
    ///     transaction can discover that another connection pinned a *different*
    ///     key first, in which case it reports a conflict and the handshake must
    ///     fail closed rather than trust the presented key.
    func upload(_ data: Data, to remotePath: String, host: String, port: Int,
               username: String, secret: SFTPSecret,
               knownHostKey: String?,
               rememberHostKey: @escaping @Sendable (String) -> HostKeyPinResult) async throws
}
