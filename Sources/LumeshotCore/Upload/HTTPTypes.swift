import Foundation

public enum HTTPMethod: String, Codable, Sendable {
    case get = "GET", post = "POST", put = "PUT", delete = "DELETE", patch = "PATCH"
}

/// A fully-resolved HTTP request ready to hand to an HTTPClient.
public struct PreparedRequest: Equatable, Sendable {
    public var method: HTTPMethod
    public var url: String
    public var headers: [String: String]
    public var body: Data?
    /// Set instead of `body` when the payload should be streamed from disk.
    /// Mutually exclusive with `body`: a client uploads from the file and never
    /// materializes it, which is what keeps a long screen recording from being
    /// read into memory in one piece.
    public var bodyFileURL: URL?
    public var contentType: String?
    public init(method: HTTPMethod, url: String, headers: [String: String] = [:],
                body: Data? = nil, bodyFileURL: URL? = nil, contentType: String? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.bodyFileURL = bodyFileURL
        self.contentType = contentType
    }
}
