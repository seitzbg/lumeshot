import Foundation
import LumeshotCore

/// Stateless: connect/transfer/close happen entirely inside `upload(_:)` via
/// the injected `transport` — this struct itself stores only Sendable value
/// types, mirroring `S3Uploader`.
public struct SFTPUploader: Uploader {
    let config: SFTPConfig
    let secret: SFTPSecret
    let transport: SFTPTransport

    public init(config: SFTPConfig, secret: SFTPSecret,
               transport: SFTPTransport = CitadelSFTPTransport()) {
        self.config = config
        self.secret = secret
        self.transport = transport
    }

    public func upload(_ file: FilePart) async throws -> UploadResult {
        let remotePath = RemotePathURLMapper.remotePath(directory: config.remoteDirectory,
                                                         filename: file.filename)
        try await transport.upload(file.data, to: remotePath, host: config.host, port: config.port,
                                   username: config.username, secret: secret)
        return UploadResult(url: RemotePathURLMapper.resultURL(publicURLBase: config.publicURLBase,
                                                                filename: file.filename))
    }
}
