import Foundation
import CryptoKit

/// Hand-rolled AWS Signature Version 4 (no AWS SDK). Deterministic given an
/// explicit `timestamp`, so it validates against the published SigV4 test vectors.
public enum SigV4Signer {
    public static func amzDate(_ date: Date) -> String { formatted(date, "yyyyMMdd'T'HHmmss'Z'") }
    public static func dateStamp(_ date: Date) -> String { formatted(date, "yyyyMMdd") }

    /// Full `Authorization` header value. `signedHeaders` must include `host` and
    /// any `x-amz-*` the caller will send, EXCEPT `x-amz-date`, which is injected
    /// here from `timestamp` so the signed date can never drift from the request.
    public static func authorizationHeader(
        method: String, canonicalURI: String, canonicalQuery: String,
        signedHeaders: [String: String], payloadHash: String,
        region: String, service: String,
        accessKeyID: String, secretAccessKey: String, timestamp: Date) -> String {

        var headers = signedHeaders
        headers["x-amz-date"] = amzDate(timestamp)

        let canonical = canonicalRequest(method: method, canonicalURI: canonicalURI,
                                         canonicalQuery: canonicalQuery,
                                         signedHeaders: headers, payloadHash: payloadHash)
        let signedNames = headers.keys.map { $0.lowercased() }.sorted().joined(separator: ";")
        let scope = "\(dateStamp(timestamp))/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate(timestamp),
            scope,
            hex(SHA256.hash(data: Data(canonical.utf8)))
        ].joined(separator: "\n")

        let key = signingKey(secret: secretAccessKey, dateStamp: dateStamp(timestamp),
                             region: region, service: service)
        let signature = hex(HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8), using: SymmetricKey(data: key)))
        return "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), "
             + "SignedHeaders=\(signedNames), Signature=\(signature)"
    }

    /// Canonical request per SigV4. `signedHeaders` are lowercased, trimmed, and
    /// sorted; every provided header is signed.
    static func canonicalRequest(method: String, canonicalURI: String, canonicalQuery: String,
                                 signedHeaders: [String: String], payloadHash: String) -> String {
        let lowered = Dictionary(uniqueKeysWithValues:
            signedHeaders.map { ($0.key.lowercased(), $0.value) })
        let names = lowered.keys.sorted()
        let canonicalHeaders = names
            .map { "\($0):\(lowered[$0]!.trimmingCharacters(in: .whitespaces))\n" }
            .joined()
        let signedNames = names.joined(separator: ";")
        return [method, canonicalURI, canonicalQuery, canonicalHeaders, signedNames, payloadHash]
            .joined(separator: "\n")
    }

    // MARK: - Crypto helpers

    private static func signingKey(secret: String, dateStamp: String,
                                   region: String, service: String) -> Data {
        let kSecret = Data("AWS4\(secret)".utf8)
        let kDate = hmac(Data(dateStamp.utf8), key: kSecret)
        let kRegion = hmac(Data(region.utf8), key: kDate)
        let kService = hmac(Data(service.utf8), key: kRegion)
        return hmac(Data("aws4_request".utf8), key: kService)
    }

    private static func hmac(_ data: Data, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// A fresh formatter per call: no shared mutable global state (Swift 6 concurrency-safe).
    private static func formatted(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f.string(from: date)
    }
}
