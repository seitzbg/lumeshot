import Foundation

public enum CustomUploaderEngine {
    /// Whether `prepare` should build the request body or only its metadata.
    public enum BodyMode: Sendable {
        case encodeInMemory
        /// Headers, URL and Content-Type only — the caller supplies the body.
        case metadataOnly
    }

    public static func prepare(config: CustomUploaderConfig, file: FilePart,
                               boundary: String,
                               bodyMode: BodyMode = .encodeInMemory) throws -> PreparedRequest {
        guard !config.requestURL.isEmpty else {
            throw UploadError.badResponse("Custom uploader has no RequestURL")
        }
        // Only the form field name differs; keep the payload source as-is so a
        // file-backed part stays file-backed all the way to the transport.
        var filePart = file
        filePart.fieldName = config.fileFormName ?? "file"
        let argFields = config.arguments.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }

        let spec: RequestBodySpec
        switch config.body {
        case .none:
            spec = .none
        case .multipartFormData:
            // Always attach the captured file (named by fileFormName, default "file").
            // A multipart screenshot upload with no file part is never intended.
            spec = .multipart(fields: argFields, file: filePart)
        case .formURLEncoded:
            spec = .formURLEncoded(argFields)
        case .json:
            spec = .json(Data((config.data ?? "").utf8))
        case .binary:
            spec = .binary(filePart)
        }
        let body: Data?
        let contentType: String?
        switch bodyMode {
        case .encodeInMemory:
            (body, contentType) = try RequestBodyEncoder.encode(spec, boundary: boundary)
        case .metadataOnly:
            // The caller streams the body itself. Encoding it here first would
            // read the whole payload into memory — exactly what staging exists
            // to avoid — only for the result to be thrown away.
            body = nil
            contentType = RequestBodyEncoder.contentType(for: spec, boundary: boundary)
        }

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
        // ShareX documents an absent/empty URL template as "the response body is
        // already the URL", so a response-only uploader is a valid .sxcu. Fall
        // back to the trimmed body, but only when it really parses as an http(s)
        // URL -- otherwise an HTML error page would be copied to the clipboard.
        let url: String
        if let resolved = resolve(config.url) {
            url = resolved
        } else if let fromBody = Self.responseBodyAsURL(context.body) {
            url = fromBody
        } else {
            throw UploadError.emptyURL
        }
        return UploadResult(url: url,
                            thumbnailURL: resolve(config.thumbnailURL),
                            deletionURL: resolve(config.deletionURL))
    }

    /// The trimmed response body when it is a usable http(s) URL, else nil.
    static func responseBodyAsURL(_ body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let c = URLComponents(string: trimmed),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty
        else { return nil }
        return trimmed
    }

    private static func escape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
