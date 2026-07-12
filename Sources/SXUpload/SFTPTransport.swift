import Foundation
import SXCore

/// Connect, auth, write `data` to `remotePath`, close — all within one call.
/// The real implementation (`CitadelSFTPTransport`) is Mac-smoke-only; `SFTPUploader`
/// is unit-tested against a fake conforming type.
public protocol SFTPTransport: Sendable {
    func upload(_ data: Data, to remotePath: String, host: String, port: Int,
               username: String, secret: SFTPSecret) async throws
}
