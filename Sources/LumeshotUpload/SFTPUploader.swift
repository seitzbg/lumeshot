import Foundation
import LumeshotCore

/// Stateless: connect/transfer/close happen entirely inside `upload(_:)` via
/// the injected `transport` — this struct itself stores only Sendable value
/// types, mirroring `S3Uploader`.
public struct SFTPUploader: Uploader {
    let config: SFTPConfig
    let secret: SFTPSecret
    let transport: SFTPTransport
    /// Invoked when a host key is trusted on first use, so the owner can pin it
    /// in settings. The uploader itself stays stateless.
    let rememberHostKey: @Sendable (String) -> Void

    public init(config: SFTPConfig, secret: SFTPSecret,
               transport: SFTPTransport = CitadelSFTPTransport(),
               rememberHostKey: @escaping @Sendable (String) -> Void = { _ in }) {
        self.config = config
        self.secret = secret
        self.transport = transport
        self.rememberHostKey = rememberHostKey
    }

    public func upload(_ file: FilePart) async throws -> UploadResult {
        let remotePath = RemotePathURLMapper.remotePath(directory: config.remoteDirectory,
                                                         filename: file.filename)
        try await transport.upload(file.data, to: remotePath, host: config.host, port: config.port,
                                   username: config.username, secret: secret,
                                   knownHostKey: config.knownHostKey,
                                   rememberHostKey: rememberHostKey)
        return UploadResult(url: RemotePathURLMapper.resultURL(publicURLBase: config.publicURLBase,
                                                                filename: file.filename))
    }
}
