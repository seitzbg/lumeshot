import Foundation

public enum CustomUploaderEngine {
    public static func prepare(config: CustomUploaderConfig, file: FilePart,
                               boundary: String) throws -> PreparedRequest {
        guard !config.requestURL.isEmpty else {
            throw UploadError.badResponse("Custom uploader has no RequestURL")
        }
        let filePart = FilePart(fieldName: config.fileFormName ?? "file",
                                filename: file.filename, mimeType: file.mimeType, data: file.data)
        let argFields = config.arguments.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }

        let spec: RequestBodySpec
        switch config.body {
        case .none:
            spec = .none
        case .multipartFormData:
            spec = .multipart(fields: argFields, file: config.fileFormName != nil ? filePart : nil)
        case .formURLEncoded:
            spec = .formURLEncoded(argFields)
        case .json:
            spec = .json(Data((config.data ?? "").utf8))
        case .binary:
            spec = .binary(filePart)
        }
        let (body, contentType) = RequestBodyEncoder.encode(spec, boundary: boundary)

        var url = config.requestURL
        if !config.parameters.isEmpty {
            let query = config.parameters.sorted { $0.key < $1.key }
                .map { "\(escape($0.key))=\(escape($0.value))" }.joined(separator: "&")
            url += (url.contains("?") ? "&" : "?") + query
        }

        return PreparedRequest(method: config.requestMethod, url: url,
                               headers: config.headers, body: body, contentType: contentType)
    }

    public static func parseResult(config: CustomUploaderConfig, status: Int,
                                   body: Data, headers: [String: String]) throws -> UploadResult {
        guard (200..<300).contains(status) else {
            throw UploadError.http(status: status,
                                   body: String(data: body, encoding: .utf8) ?? "")
        }
        let context = ResponseContext(body: String(data: body, encoding: .utf8) ?? "",
                                      headers: headers, regexList: config.regexList)
        func resolve(_ template: String?) -> String? {
            guard let template, !template.isEmpty else { return nil }
            let value = ResponseURLParser.resolve(template, context: context)
            return value.isEmpty ? nil : value
        }
        guard let url = resolve(config.url) else { throw UploadError.emptyURL }
        return UploadResult(url: url,
                            thumbnailURL: resolve(config.thumbnailURL),
                            deletionURL: resolve(config.deletionURL))
    }

    private static func escape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
