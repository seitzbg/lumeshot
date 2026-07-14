import Foundation

public struct UploadResult: Equatable, Sendable {
    public var url: String
    public var thumbnailURL: String?
    public var deletionURL: String?
    public init(url: String, thumbnailURL: String? = nil, deletionURL: String? = nil) {
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.deletionURL = deletionURL
    }
}

public enum UploadError: Error, Equatable, Sendable {
    case http(status: Int, body: String)
    case emptyURL
    case unsupported(String)
    case missingCredential(String)
    case transport(String)
    case badResponse(String)
}
