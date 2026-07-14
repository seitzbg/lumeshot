import Foundation

public enum CustomUploaderBody: String, Codable, Sendable {
    case none = "None"
    case multipartFormData = "MultipartFormData"
    case formURLEncoded = "FormURLEncoded"
    case json = "JSON"
    case binary = "Binary"
}

public struct CustomUploaderConfig: Codable, Equatable, Sendable {
    public var version: String?
    public var name: String?
    public var requestMethod: HTTPMethod
    public var requestURL: String
    public var parameters: [String: String]
    public var headers: [String: String]
    public var body: CustomUploaderBody
    public var arguments: [String: String]
    public var fileFormName: String?
    public var data: String?
    public var regexList: [String]
    public var url: String?
    public var thumbnailURL: String?
    public var deletionURL: String?
    public var errorMessage: String?

    public init(requestURL: String,
                requestMethod: HTTPMethod = .post,
                name: String? = nil,
                headers: [String: String] = [:],
                parameters: [String: String] = [:],
                body: CustomUploaderBody = .multipartFormData,
                arguments: [String: String] = [:],
                fileFormName: String? = nil,
                data: String? = nil,
                regexList: [String] = [],
                url: String? = nil,
                thumbnailURL: String? = nil,
                deletionURL: String? = nil,
                errorMessage: String? = nil,
                version: String? = nil) {
        self.requestURL = requestURL
        self.requestMethod = requestMethod
        self.name = name
        self.headers = headers
        self.parameters = parameters
        self.body = body
        self.arguments = arguments
        self.fileFormName = fileFormName
        self.data = data
        self.regexList = regexList
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.deletionURL = deletionURL
        self.errorMessage = errorMessage
        self.version = version
    }

    // ShareX .sxcu keys are PascalCase.
    private enum CodingKeys: String, CodingKey {
        case version = "Version"
        case name = "Name"
        case requestMethod = "RequestMethod"
        case requestURL = "RequestURL"
        case parameters = "Parameters"
        case headers = "Headers"
        case body = "Body"
        case arguments = "Arguments"
        case fileFormName = "FileFormName"
        case data = "Data"
        case regexList = "RegexList"
        case url = "URL"
        case thumbnailURL = "ThumbnailURL"
        case deletionURL = "DeletionURL"
        case errorMessage = "ErrorMessage"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestURL = try c.decodeIfPresent(String.self, forKey: .requestURL) ?? ""
        requestMethod = try c.decodeIfPresent(HTTPMethod.self, forKey: .requestMethod) ?? .post
        name = try c.decodeIfPresent(String.self, forKey: .name)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        parameters = try c.decodeIfPresent([String: String].self, forKey: .parameters) ?? [:]
        body = try c.decodeIfPresent(CustomUploaderBody.self, forKey: .body) ?? .multipartFormData
        arguments = try c.decodeIfPresent([String: String].self, forKey: .arguments) ?? [:]
        fileFormName = try c.decodeIfPresent(String.self, forKey: .fileFormName)
        data = try c.decodeIfPresent(String.self, forKey: .data)
        regexList = try c.decodeIfPresent([String].self, forKey: .regexList) ?? []
        url = try c.decodeIfPresent(String.self, forKey: .url)
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL)
        deletionURL = try c.decodeIfPresent(String.self, forKey: .deletionURL)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    /// Parse a .sxcu file. Throws `UploadError.badResponse` on malformed JSON,
    /// `UploadError.unsupported` for body types M2a can't execute (e.g. XML).
    public static func parse(_ data: Data) throws -> CustomUploaderConfig {
        // Reject an unsupported body BEFORE decoding maps it to a case: the raw
        // "Body" string may be a value the enum doesn't model (e.g. "XML").
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let bodyString = object["Body"] as? String,
           CustomUploaderBody(rawValue: bodyString) == nil {
            throw UploadError.unsupported("Unsupported request body type: \(bodyString)")
        }
        do {
            return try JSONDecoder().decode(CustomUploaderConfig.self, from: data)
        } catch {
            throw UploadError.badResponse("Invalid .sxcu JSON: \(error.localizedDescription)")
        }
    }
}
