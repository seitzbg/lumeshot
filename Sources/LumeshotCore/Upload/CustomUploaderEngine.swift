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

    /// Parses an upload response into a result.
    ///
    /// `requirePublicURL` controls what the resolved result URL is allowed to
    /// be. For a real destination the result IS the public link, so it must be
    /// an absolute http(s) URL (a `file:` URL, custom scheme or HTML page must
    /// not be reported as success and copied to the clipboard). Picsur, however,
    /// reuses this engine to extract a bare image id and composes the URL
    /// itself, so it passes `false` to keep raw-field extraction working.
    public static func parseResult(config: CustomUploaderConfig, status: Int,
                                   body: Data, headers: [String: String],
                                   requirePublicURL: Bool = true) throws -> UploadResult {
        guard (200..<300).contains(status) else {
            throw UploadError.http(status: status,
                                   body: String(data: body, encoding: .utf8) ?? "")
        }
        let context = ResponseContext(body: String(data: body, encoding: .utf8) ?? "",
                                      headers: headers, regexList: config.regexList)
        // Optional extras: a thumbnail or deletion link that cannot be extracted
        // — a missing token, or one present but empty — is dropped. The upload
        // itself succeeded, and losing a deletion token is not worth failing it
        // over, but an empty token must not assemble into a broken link either.
        func resolveOptional(_ template: String?) -> String? {
            guard let template, !template.isEmpty else { return nil }
            return ResponseURLParser.resolveNonEmpty(template, context: context)
        }
        // The result URL is not optional. A template that cannot be filled in is
        // a failed upload, however healthy the status code looked: the literal
        // parts of the template would otherwise assemble into a plausible but
        // wrong link, which then replaces the screenshot on the clipboard. An
        // empty required token is rejected the same way (resolveNonEmpty), so a
        // "https://host/i/{json:data.id}.png" with an empty id does not slip
        // through as "https://host/i/.png".
        func resolveRequired(_ template: String) throws -> String {
            guard let value = ResponseURLParser.resolveNonEmpty(template, context: context) else {
                throw UploadError.badResponse(
                    "The response did not contain the values the URL template asks for.")
            }
            return value
        }
        // An absent/empty .sxcu URL template means "the response body is
        // already the URL", so a response-only uploader is a valid .sxcu. Fall
        // back to the trimmed body, but only when it really parses as an http(s)
        // URL -- otherwise an HTML error page would be copied to the clipboard.
        let url: String
        if let template = config.url, !template.isEmpty {
            let resolved = try resolveRequired(template)
            if requirePublicURL, let web = WebLink.openable(resolved) {
                url = web.absoluteString
            } else if requirePublicURL {
                throw UploadError.badResponse(
                    "The upload succeeded but the result is not a usable http(s) link.")
            } else {
                url = resolved
            }
        } else if let fromBody = Self.responseBodyAsURL(context.body) {
            url = fromBody
        } else {
            throw UploadError.emptyURL
        }
        return UploadResult(url: url,
                            thumbnailURL: resolveOptional(config.thumbnailURL),
                            deletionURL: resolveOptional(config.deletionURL))
    }

    /// The trimmed response body when it is a usable http(s) URL, else nil.
    static func responseBodyAsURL(_ body: String) -> String? {
        WebLink.openable(body)?.absoluteString
    }

    private static func escape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
