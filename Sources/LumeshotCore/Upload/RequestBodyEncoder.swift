import Foundation

public struct FilePart: Equatable, Sendable {
    public var fieldName: String
    public var filename: String
    public var mimeType: String
    public var data: Data
    public init(fieldName: String, filename: String, mimeType: String, data: Data) {
        self.fieldName = fieldName
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

public enum RequestBodySpec: Equatable, Sendable {
    case none
    case multipart(fields: [(String, String)], file: FilePart?)
    case formURLEncoded([(String, String)])
    case json(Data)
    case binary(FilePart)

    public static func == (lhs: RequestBodySpec, rhs: RequestBodySpec) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): return true
        case let (.multipart(lf, lfile), .multipart(rf, rfile)):
            return lf.elementsEqual(rf, by: ==) && lfile == rfile
        case let (.formURLEncoded(l), .formURLEncoded(r)):
            return l.elementsEqual(r, by: ==)
        case let (.json(l), .json(r)): return l == r
        case let (.binary(l), .binary(r)): return l == r
        default: return false
        }
    }
}

public enum RequestBodyEncoder {
    public static func encode(_ spec: RequestBodySpec,
                              boundary: String) -> (body: Data?, contentType: String?) {
        switch spec {
        case .none:
            return (nil, nil)

        case let .multipart(fields, file):
            var data = Data()
            func append(_ s: String) { data.append(Data(s.utf8)) }
            for (name, value) in fields {
                append("--\(boundary)\r\n")
                append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                append("\(value)\r\n")
            }
            if let file {
                append("--\(boundary)\r\n")
                append("Content-Disposition: form-data; name=\"\(file.fieldName)\"; "
                       + "filename=\"\(file.filename)\"\r\n")
                append("Content-Type: \(file.mimeType)\r\n\r\n")
                data.append(file.data)
                append("\r\n")
            }
            append("--\(boundary)--\r\n")
            return (data, "multipart/form-data; boundary=\(boundary)")

        case let .formURLEncoded(pairs):
            let encoded = pairs.map { "\(formEscape($0.0))=\(formEscape($0.1))" }.joined(separator: "&")
            return (Data(encoded.utf8), "application/x-www-form-urlencoded")

        case let .json(payload):
            return (payload, "application/json")

        case let .binary(file):
            return (file.data, file.mimeType)
        }
    }

    /// Percent-encode for application/x-www-form-urlencoded (space → %20, not '+').
    private static func formEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
