import Foundation
import LumeshotCore

/// Stateless: connect/transfer/close happen entirely inside `upload(_:)` via
/// the injected `transport` — this struct itself stores only Sendable value
/// types, mirroring `S3Uploader`.
public struct FTPUploader: Uploader {
    let config: FTPConfig
    let secret: FTPSecret
    let transport: FTPTransport

    public init(config: FTPConfig, secret: FTPSecret, transport: FTPTransport = CurlFTPTransport()) {
        self.config = config
        self.secret = secret
        self.transport = transport
    }

    public func upload(_ file: FilePart) async throws -> UploadResult {
        let remotePath = RemotePathURLMapper.remotePath(directory: config.remoteDirectory,
                                                         filename: file.filename)
        let url = "ftp://\(config.host):\(config.port)\(remotePath.hasPrefix("/") ? remotePath : "/" + remotePath)"
        try await transport.upload(file.data, to: url, username: config.username,
                                   password: secret.password, useTLS: config.useTLS)
        return UploadResult(url: RemotePathURLMapper.resultURL(publicURLBase: config.publicURLBase,
                                                                filename: file.filename))
    }
}
