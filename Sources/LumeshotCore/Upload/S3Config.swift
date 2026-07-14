import Foundation

public enum S3AddressingStyle: String, Codable, Sendable {
    case virtualHost = "VirtualHost"
    case path = "Path"
}

/// Non-secret S3 destination config. Credentials live in the Keychain
/// (see `S3Credentials`), keyed by the owning destination's id — never here.
public struct S3Config: Codable, Equatable, Sendable {
    public var region: String
    public var endpoint: String          // base host, no bucket, e.g. "s3.us-east-1.amazonaws.com"
    public var bucket: String
    public var objectPrefix: String      // e.g. "screens/"; "" means the bucket root
    public var addressingStyle: S3AddressingStyle
    public var acl: String?              // e.g. "public-read"; nil sends no ACL header
    public var customDomain: String?     // CDN/custom domain for the result URL, e.g. "cdn.example.com"

    public init(region: String, endpoint: String, bucket: String,
                objectPrefix: String = "", addressingStyle: S3AddressingStyle = .virtualHost,
                acl: String? = nil, customDomain: String? = nil) {
        self.region = region
        self.endpoint = endpoint
        self.bucket = bucket
        self.objectPrefix = objectPrefix
        self.addressingStyle = addressingStyle
        self.acl = acl
        self.customDomain = customDomain
    }
}
