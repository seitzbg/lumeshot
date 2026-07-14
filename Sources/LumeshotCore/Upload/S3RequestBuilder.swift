import Foundation
import CryptoKit

public struct SigV4Credentials: Sendable, Equatable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public init(accessKeyID: String, secretAccessKey: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }
}

/// Builds a signed S3 `PUT` object request and derives the public result URL.
public enum S3RequestBuilder {
    public static func objectKey(config: S3Config, filename: String) -> String {
        let p = config.objectPrefix
        if p.isEmpty { return filename }
        return p.hasSuffix("/") ? p + filename : p + "/" + filename
    }

    public static func build(config: S3Config, credentials: SigV4Credentials,
                             file: FilePart, now: Date) throws -> PreparedRequest {
        guard !config.endpoint.isEmpty, !config.bucket.isEmpty else {
            throw UploadError.unsupported("S3 destination missing endpoint or bucket")
        }
        let key = objectKey(config: config, filename: file.filename)
        let host: String
        let path: String
        switch config.addressingStyle {
        case .virtualHost:
            host = "\(config.bucket).\(config.endpoint)"
            path = "/" + encodePath(key)
        case .path:
            host = config.endpoint
            path = "/" + encodeSegment(config.bucket) + "/" + encodePath(key)
        }
        let payloadHash = hex(SHA256.hash(data: file.data))

        var signed: [String: String] = ["host": host, "x-amz-content-sha256": payloadHash]
        if let acl = config.acl, !acl.isEmpty { signed["x-amz-acl"] = acl }

        let auth = SigV4Signer.authorizationHeader(
            method: "PUT", canonicalURI: path, canonicalQuery: "",
            signedHeaders: signed, payloadHash: payloadHash,
            region: config.region, service: "s3",
            accessKeyID: credentials.accessKeyID,
            secretAccessKey: credentials.secretAccessKey, timestamp: now)

        var headers = signed
        headers.removeValue(forKey: "host")          // URLSession derives Host from the URL
        headers["x-amz-date"] = SigV4Signer.amzDate(now)
        headers["Authorization"] = auth

        return PreparedRequest(method: .put, url: "https://\(host)\(path)",
                               headers: headers, body: file.data, contentType: file.mimeType)
    }

    public static func resultURL(config: S3Config, filename: String) -> String {
        let key = encodePath(objectKey(config: config, filename: filename))
        if let domain = config.customDomain, !domain.isEmpty {
            return "https://\(domain)/\(key)"
        }
        switch config.addressingStyle {
        case .virtualHost: return "https://\(config.bucket).\(config.endpoint)/\(key)"
        case .path:        return "https://\(config.endpoint)/\(config.bucket)/\(key)"
        }
    }

    // AWS URI-encode: unreserved kept verbatim, everything else %XX (uppercase hex).
    private static func encodeSegment(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
    private static func encodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { encodeSegment(String($0)) }.joined(separator: "/")
    }
    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
