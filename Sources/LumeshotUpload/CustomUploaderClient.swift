import Foundation
import LumeshotCore

public struct CustomUploaderClient: Uploader {
    private let config: CustomUploaderConfig
    private let http: HTTPClient
    private let boundaryProvider: @Sendable () -> String

    /// Writes prologue + file bytes + epilogue to a temp file, copying the
    /// payload in chunks so peak memory is one chunk rather than the whole
    /// recording.
    private static func stageMultipartBody(config: CustomUploaderConfig, file: FilePart,
                                           boundary: String) throws -> URL {
        guard case .file(let sourceURL, _) = file.source else {
            throw UploadError.unsupported("stageMultipartBody requires a file-backed part")
        }
        var part = file
        part.fieldName = config.fileFormName ?? "file"
        let fields = config.arguments.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }

        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumeshot-upload-\(UUID().uuidString).body")
        FileManager.default.createFile(atPath: stagedURL.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: stagedURL) else {
            throw UploadError.transport("Could not stage the upload body on disk.")
        }
        do {
            defer { try? out.close() }
            try out.write(contentsOf: RequestBodyEncoder.multipartPrologue(
                fields: fields, file: part, boundary: boundary))
            let input = try FileHandle(forReadingFrom: sourceURL)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
            try out.write(contentsOf: RequestBodyEncoder.multipartEpilogue(boundary: boundary))
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }
        return stagedURL
    }

    public init(config: CustomUploaderConfig, http: HTTPClient,
                boundaryProvider: @escaping @Sendable () -> String = {
                    "SXBoundary-" + UUID().uuidString
                }) {
        self.config = config
        self.http = http
        self.boundaryProvider = boundaryProvider
    }

    public func upload(_ file: FilePart) async throws -> UploadResult {
        let boundary = boundaryProvider()
        // A multipart body built in memory holds the payload twice: once as the
        // FilePart and again inside the assembled body. For a file-backed part
        // (a screen recording) that is the difference between paging and being
        // killed, so stage the request body to disk and stream it instead —
        // and ask prepare() for metadata only, or it would build the very
        // allocation we are trying to avoid just to have it discarded.
        let stream = { if case .file = file.source { return config.body == .multipartFormData }
                       return false }()

        var request = try CustomUploaderEngine.prepare(
            config: config, file: file, boundary: boundary,
            bodyMode: stream ? .metadataOnly : .encodeInMemory)

        var staged: URL?
        defer { if let staged { try? FileManager.default.removeItem(at: staged) } }
        if stream {
            let url = try Self.stageMultipartBody(config: config, file: file, boundary: boundary)
            staged = url
            request.bodyFileURL = url
        }
        let response = try await http.send(request)
        return try CustomUploaderEngine.parseResult(config: config, status: response.status,
                                                    body: response.body, headers: response.headers)
    }
}
