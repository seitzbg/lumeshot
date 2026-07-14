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
    public var contentType: String?
    public init(method: HTTPMethod, url: String, headers: [String: String] = [:],
                body: Data? = nil, contentType: String? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.contentType = contentType
    }
}
