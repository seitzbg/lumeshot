import Foundation
import SXCore

/// S3-compatible uploader: SigV4-signed `PUT` object, result URL derived from
/// config (no response parsing — S3 returns an empty 200 body on success).
public struct S3Uploader: Uploader {
    private let config: S3Config
    private let credentials: SigV4Credentials
    private let http: HTTPClient
    private let now: @Sendable () -> Date

    public init(config: S3Config, credentials: SigV4Credentials, http: HTTPClient,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.credentials = credentials
        self.http = http
        self.now = now
    }

    public func upload(_ file: FilePart) async throws -> UploadResult {
        let request = try S3RequestBuilder.build(config: config, credentials: credentials,
                                                 file: file, now: now())
        let response = try await http.send(request)
        guard (200..<300).contains(response.status) else {
            throw UploadError.http(status: response.status,
                                   body: String(data: response.body, encoding: .utf8) ?? "")
        }
        return UploadResult(url: S3RequestBuilder.resultURL(config: config, filename: file.filename))
    }
}
