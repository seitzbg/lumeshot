import Foundation
import LumeshotCore

/// Anonymous Imgur upload. OAuth (authenticated albums) is deferred.
public struct ImgurUploader: Uploader {
    private let clientID: String
    private let http: HTTPClient

    public init(clientID: String, http: HTTPClient) {
        self.clientID = clientID
        self.http = http
    }

    public func upload(_ file: FilePart) async throws -> UploadResult {
        var config = CustomUploaderConfig(requestURL: "https://api.imgur.com/3/image")
        config.headers = ["Authorization": "Client-ID \(clientID)"]
        config.body = .multipartFormData
        config.fileFormName = "image"
        config.url = "{json:data.link}"
        config.deletionURL = "https://imgur.com/delete/{json:data.deletehash}"
        return try await CustomUploaderClient(config: config, http: http).upload(file)
    }
}
