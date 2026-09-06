import Foundation

/// Refuses to materialize a payload larger than this. Screen recordings are
/// uncapped in duration, and every current transport needs the bytes resident
/// at some point, so an unbounded read is a process-killer rather than a slow
/// upload. 2 GiB is far above any plausible screenshot or short clip.
public let maxUploadBytes = 2 * 1024 * 1024 * 1024

public struct FilePart: Equatable, Sendable {
    /// Where the payload lives. A recording can be hundreds of megabytes, so it
    /// stays on disk until something actually needs the bytes — and the
    /// multipart path never needs them all at once.
    public enum Source: Equatable, Sendable {
        case data(Data)
        case file(URL, byteCount: Int)
    }

    public var fieldName: String
    public var filename: String
    public var mimeType: String
    public var source: Source

    public init(fieldName: String, filename: String, mimeType: String, data: Data) {
        self.init(fieldName: fieldName, filename: filename, mimeType: mimeType,
                  source: .data(data))
    }

    public init(fieldName: String, filename: String, mimeType: String, source: Source) {
        self.fieldName = fieldName
        self.filename = filename
        self.mimeType = mimeType
        self.source = source
    }

    /// File-backed part. Throws rather than silently uploading nothing if the
    /// file has gone missing.
    public static func file(fieldName: String, filename: String, mimeType: String,
                            url: URL) throws -> FilePart {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return FilePart(fieldName: fieldName, filename: filename, mimeType: mimeType,
                        source: .file(url, byteCount: size))
    }

    public var byteCount: Int {
        switch source {
        case .data(let d): return d.count
        case .file(_, let count): return count
        }
    }

    /// The whole payload in memory. Transports that cannot stream call this —
    /// deliberately throwing, so an oversized file fails with a clear error
    /// instead of being allocated and taking the process with it.
    public func readData() throws -> Data {
        guard byteCount <= maxUploadBytes else {
            throw UploadError.unsupported(
                "This file is \(byteCount / (1024 * 1024)) MB, above the \(maxUploadBytes / (1024 * 1024)) MB upload limit.")
        }
        switch source {
        case .data(let d):
            return d
        case .file(let url, _):
            // .mappedIfSafe: let the kernel page it in rather than committing
            // the whole thing to anonymous memory up front.
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
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
    /// Throwing, because a payload that cannot be read must not silently become
    /// an empty body: a `.binary` uploader would then POST nothing and the
    /// response could still parse as success.
    public static func encode(_ spec: RequestBodySpec,
                              boundary: String) throws -> (body: Data?, contentType: String?) {
        switch spec {
        case .none:
            return (nil, nil)

        case let .multipart(fields, file):
            var data = multipartPrologue(fields: fields, file: file, boundary: boundary)
            if let file {
                data.append(try file.readData())
                data.append(multipartEpilogue(boundary: boundary))
            } else {
                data.append(Data("--\(boundary)--\r\n".utf8))
            }
            return (data, multipartContentType(boundary: boundary))

        case let .formURLEncoded(pairs):
            let encoded = pairs.map { "\(formEscape($0.0))=\(formEscape($0.1))" }.joined(separator: "&")
            return (Data(encoded.utf8), "application/x-www-form-urlencoded")

        case let .json(payload):
            return (payload, "application/json")

        case let .binary(file):
            return (try file.readData(), file.mimeType)
        }
    }

    /// The Content-Type a spec would produce, without encoding anything.
    public static func contentType(for spec: RequestBodySpec, boundary: String) -> String? {
        switch spec {
        case .none: return nil
        case .multipart: return multipartContentType(boundary: boundary)
        case .formURLEncoded: return "application/x-www-form-urlencoded"
        case .json: return "application/json"
        case .binary(let file): return file.mimeType
        }
    }

    public static func multipartContentType(boundary: String) -> String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// Everything before the file bytes. Split out so a file-backed upload can
    /// stream the payload straight from disk into a staged body instead of
    /// building the whole request in memory.
    public static func multipartPrologue(fields: [(String, String)], file: FilePart?,
                                         boundary: String) -> Data {
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
        }
        return data
    }

    /// Everything after the file bytes.
    public static func multipartEpilogue(boundary: String) -> Data {
        Data("\r\n--\(boundary)--\r\n".utf8)
    }

    /// Percent-encode for application/x-www-form-urlencoded (space → %20, not '+').
    private static func formEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
