import Foundation
import LumeshotCore

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: PreparedRequest) async throws -> HTTPResponse {
        guard let url = URL(string: request.url) else {
            // Deliberately not interpolated: by this point the URL has been
            // injected with any Keychain-held credential, and this string
            // reaches the log and a user-visible notification.
            throw UploadError.transport("The uploader's request URL is not a valid URL.")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if let contentType = request.contentType {
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            if let fileURL = request.bodyFileURL {
                // Streams from disk: the payload is never held in memory here.
                (data, response) = try await session.upload(for: urlRequest, fromFile: fileURL)
            } else {
                urlRequest.httpBody = request.body
                (data, response) = try await session.data(for: urlRequest)
            }
        } catch {
            throw UploadError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.badResponse("Non-HTTP response")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { headers[k] = v }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}
