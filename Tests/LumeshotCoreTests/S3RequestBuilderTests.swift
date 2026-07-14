import Foundation
import CryptoKit
import Testing
@testable import LumeshotCore

@Suite struct S3RequestBuilderTests {
    private let creds = SigV4Credentials(accessKeyID: "AKID", secretAccessKey: "SECRET")
    private var now: Date { Date(timeIntervalSince1970: 1_440_938_160) } // 2015-08-30T12:36:00Z
    private func png(_ bytes: [UInt8] = [0x89, 0x50]) -> FilePart {
        FilePart(fieldName: "file", filename: "shot.png", mimeType: "image/png", data: Data(bytes))
    }

    @Test func objectKeyJoinsPrefixAndFilename() {
        let base = S3Config(region: "r", endpoint: "e", bucket: "b")
        #expect(S3RequestBuilder.objectKey(config: base, filename: "a.png") == "a.png")
        var withSlash = base; withSlash.objectPrefix = "screens/"
        #expect(S3RequestBuilder.objectKey(config: withSlash, filename: "a.png") == "screens/a.png")
        var noSlash = base; noSlash.objectPrefix = "screens"
        #expect(S3RequestBuilder.objectKey(config: noSlash, filename: "a.png") == "screens/a.png")
    }

    @Test func virtualHostRequestIsSignedAndAddressed() throws {
        var config = S3Config(region: "us-east-1", endpoint: "s3.us-east-1.amazonaws.com",
                              bucket: "shots", objectPrefix: "screens/")
        config.addressingStyle = .virtualHost
        let file = png()
        let req = try S3RequestBuilder.build(config: config, credentials: creds, file: file, now: now)

        #expect(req.method == .put)
        #expect(req.url == "https://shots.s3.us-east-1.amazonaws.com/screens/shot.png")
        #expect(req.body == file.data)
        #expect(req.contentType == "image/png")
        #expect(req.headers["host"] == nil)          // URLSession sets Host from the URL
        #expect(req.headers["Authorization"]?.hasPrefix("AWS4-HMAC-SHA256 ") == true)
        #expect(req.headers["x-amz-date"] == "20150830T123600Z")
        let expectedHash = SHA256.hash(data: file.data).map { String(format: "%02x", $0) }.joined()
        #expect(req.headers["x-amz-content-sha256"] == expectedHash)
        #expect(req.headers["x-amz-acl"] == nil)     // no ACL configured
    }

    @Test func pathStyleAddressesBucketInThePath() throws {
        var config = S3Config(region: "us-east-1", endpoint: "s3.amazonaws.com", bucket: "shots")
        config.addressingStyle = .path
        let req = try S3RequestBuilder.build(config: config, credentials: creds, file: png(), now: now)
        #expect(req.url == "https://s3.amazonaws.com/shots/shot.png")
    }

    @Test func aclIsSignedAndSent() throws {
        var config = S3Config(region: "us-east-1", endpoint: "s3.amazonaws.com", bucket: "shots")
        config.acl = "public-read"
        let req = try S3RequestBuilder.build(config: config, credentials: creds, file: png(), now: now)
        #expect(req.headers["x-amz-acl"] == "public-read")
        #expect(req.headers["Authorization"]?.contains("x-amz-acl") == true) // in SignedHeaders
    }

    @Test func resultURLPrefersCustomDomainThenAddressingStyle() {
        var vhost = S3Config(region: "r", endpoint: "s3.amazonaws.com", bucket: "shots",
                             objectPrefix: "screens/")
        #expect(S3RequestBuilder.resultURL(config: vhost, filename: "a.png")
                == "https://shots.s3.amazonaws.com/screens/a.png")
        vhost.addressingStyle = .path
        #expect(S3RequestBuilder.resultURL(config: vhost, filename: "a.png")
                == "https://s3.amazonaws.com/shots/screens/a.png")
        vhost.customDomain = "cdn.example.com"
        #expect(S3RequestBuilder.resultURL(config: vhost, filename: "a.png")
                == "https://cdn.example.com/screens/a.png")
    }

    @Test func missingEndpointThrows() {
        let config = S3Config(region: "r", endpoint: "", bucket: "b")
        #expect(throws: UploadError.self) {
            _ = try S3RequestBuilder.build(config: config, credentials: creds, file: png(), now: now)
        }
    }
}
