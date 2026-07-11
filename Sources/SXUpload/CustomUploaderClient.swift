import Foundation
import SXCore

public struct CustomUploaderClient: Uploader {
    private let config: CustomUploaderConfig
    private let http: HTTPClient
    private let boundaryProvider: @Sendable () -> String

    public init(config: CustomUploaderConfig, http: HTTPClient,
                boundaryProvider: @escaping @Sendable () -> String = {
                    "SXBoundary-" + UUID().uuidString
                }) {
        self.config = config
        self.http = http
        self.boundaryProvider = boundaryProvider
    }

    public func upload(_ file: FilePart) async throws -> UploadResult {
        let request = try CustomUploaderEngine.prepare(config: config, file: file,
                                                       boundary: boundaryProvider())
        let response = try await http.send(request)
        return try CustomUploaderEngine.parseResult(config: config, status: response.status,
                                                    body: response.body, headers: response.headers)
    }
}
