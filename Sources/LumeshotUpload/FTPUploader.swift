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
        // In curl's FTP URL syntax the path is relative to the login directory,
        // and an absolute path needs a second slash after the host. Forcing a
        // single leading slash made every configured directory relative: a
        // destination set to "/var/www/uploads" wrote to <login>/var/www/uploads
        // while the public link was built as though it had not. Servers that
        // chroot the login to "/" hid this, because there the two coincide.
        //
        // So preserve what the user configured. An empty directory stays the
        // login directory, as before.
        let remotePath = config.remoteDirectory.isEmpty
            ? file.filename
            : RemotePathURLMapper.remotePath(directory: config.remoteDirectory,
                                             filename: file.filename)
        // libcurl parses this as a URL, so the path must be percent-encoded:
        // a filename with a space or "#" otherwise produces an invalid URL or
        // silently truncates at the fragment.
        let url = "ftp://\(config.host):\(config.port)/\(RemotePathURLMapper.encodePath(remotePath))"
        try await transport.upload(try file.readData(), to: url, username: config.username,
                                   password: secret.password, useTLS: config.useTLS)
        return UploadResult(url: RemotePathURLMapper.resultURL(publicURLBase: config.publicURLBase,
                                                                filename: file.filename))
    }
}
