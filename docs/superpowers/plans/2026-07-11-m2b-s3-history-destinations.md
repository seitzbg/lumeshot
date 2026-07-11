# M2b — S3, History Browser & Destination Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an S3-compatible uploader (hand-rolled SigV4), a SwiftUI history browser, and a SwiftUI destination-management UI to sharex-mac, so destinations can be created/edited/removed and captures browsed without hand-editing `settings.json`.

**Architecture:** Pure, testable logic lands in `SXCore` (SigV4 signer, S3 request builder, S3 credential vault, settings-management helpers, history queries) and `SXUpload` (`S3Uploader`). The two new windows are thin SwiftUI shells hosted from the existing AppKit menu-bar app via `NSHostingController`; all persistence goes through the existing `SettingsStore` + Keychain. No new package dependencies — CryptoKit, SwiftUI, URLSession, Security, and system SQLite are all system frameworks.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM (tools 6.0), AppKit + SwiftUI, CryptoKit (HMAC/SHA256), system SQLite3, Security (Keychain).

## Global Constraints

Every task's requirements implicitly include these (copied from the design spec, `docs/superpowers/specs/2026-07-10-sharex-mac-design.md`):

- **Swift 6 strict concurrency**, `@MainActor` isolation for all AppKit/SwiftUI/UI-state types.
- **Platform:** macOS 15+, Apple Silicon (arm64) only.
- **No runtime dependencies outside the bundle** — only CryptoKit / URLSession / Security / SwiftUI / system SQLite3. Do **not** add any SwiftPM dependency; `Package.swift` stays unchanged.
- **Bundle ID `org.sharexmac.app`** is immutable (TCC/Keychain/settings key off it).
- **Local-first invariant:** disk write precedes any upload; a failed upload never loses the artifact. (M2b does not touch the capture path, but must not regress it.)
- **Fail loud:** no silent catch-and-drop. Surface errors via `AppLog.log` and/or a user notification; never swallow.
- **Secrets never persist in `settings.json`.** API keys, tokens, S3 secret/access keys live only in the Keychain, referenced by destination id. The only secret-slot value allowed in `settings.json` is the `SecretVault.sentinel` (`$keychain$`).
- **No AI-attribution boilerplate anywhere** — not in code comments, commits, docs, or reports.

---

### Task 1: S3Config model + destination wiring

**Files:**
- Create: `Sources/SXCore/Upload/S3Config.swift`
- Modify: `Sources/SXCore/Upload/UploadSettings.swift` (add `.s3` kind + `s3Config` field)
- Modify: `Sources/SXApp/UploadService.swift` (add throwing `.s3` placeholder so the switch stays exhaustive — Task 8 replaces it)
- Test: `Tests/SXCoreTests/S3ConfigTests.swift`

**Interfaces:**
- Produces: `S3AddressingStyle` (`.virtualHost` / `.path`); `S3Config { region, endpoint, bucket, objectPrefix, addressingStyle, acl?, customDomain? }`; `UploadDestinationKind.s3`; `UploadDestination.s3Config: S3Config?`.
- Consumes: existing `UploadDestination`, `UploadSettings`, `UploadError`.

**Note:** Adding a case to `UploadDestinationKind` makes `UploadService.uploader(for:)`'s `switch` non-exhaustive and the whole package would fail to build. This task therefore adds a temporary `.s3` branch that throws `UploadError.unsupported("S3 upload not wired yet")`. Task 8 replaces it with the real implementation. `UploadService` is in the untested `SXApp` target, so its only gate here is that `swift build` succeeds.

- [ ] **Step 1: Write the failing test**

Create `Tests/SXCoreTests/S3ConfigTests.swift`:

```swift
import Foundation
import Testing
@testable import SXCore

@Suite struct S3ConfigTests {
    @Test func s3DestinationRoundTripsThroughUploadSettings() throws {
        let config = S3Config(region: "us-east-1", endpoint: "s3.us-east-1.amazonaws.com",
                              bucket: "shots", objectPrefix: "screens/",
                              addressingStyle: .path, acl: "public-read",
                              customDomain: "cdn.example.com")
        let dest = UploadDestination(id: "d1", name: "My S3", kind: .s3, s3Config: config)
        let settings = UploadSettings(uploadAfterCapture: true, activeDestinationID: "d1",
                                      destinations: [dest])

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(UploadSettings.self, from: data)

        #expect(decoded == settings)
        #expect(decoded.destinations.first?.kind == .s3)
        #expect(decoded.destinations.first?.s3Config?.bucket == "shots")
        #expect(decoded.destinations.first?.s3Config?.addressingStyle == .path)
    }

    @Test func s3ConfigDefaultsAreVirtualHostNoAcl() {
        let config = S3Config(region: "auto", endpoint: "acct.r2.cloudflarestorage.com",
                              bucket: "b")
        #expect(config.addressingStyle == .virtualHost)
        #expect(config.acl == nil)
        #expect(config.objectPrefix == "")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/remote.sh test 2>&1 | tail -30`
Expected: FAIL — `cannot find 'S3Config' in scope` / `type 'UploadDestinationKind' has no member 's3'`.

- [ ] **Step 3: Create the S3Config model**

Create `Sources/SXCore/Upload/S3Config.swift`:

```swift
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
```

- [ ] **Step 4: Wire the new kind and field into UploadSettings**

In `Sources/SXCore/Upload/UploadSettings.swift`, add the `.s3` case to the kind enum:

```swift
public enum UploadDestinationKind: String, Codable, Sendable {
    case customUploader
    case imgur
    case s3
}
```

Add the `s3Config` stored property to `UploadDestination` (right after `imgurClientID`):

```swift
    public var imgurClientID: String?                  // non-secret; anonymous client id
    public var s3Config: S3Config?                     // non-secret S3 config; secrets → Keychain
```

Replace the initializer so all three optional payloads default to `nil` (keeps existing call sites in `SxcuImporter` compiling):

```swift
    public init(id: String, name: String, kind: UploadDestinationKind,
                customUploader: CustomUploaderConfig? = nil,
                imgurClientID: String? = nil,
                s3Config: S3Config? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.customUploader = customUploader
        self.imgurClientID = imgurClientID
        self.s3Config = s3Config
    }
```

- [ ] **Step 5: Keep UploadService's switch exhaustive (placeholder)**

In `Sources/SXApp/UploadService.swift`, add a temporary `.s3` branch inside `uploader(for:)`'s `switch destination.kind` (Task 8 replaces this):

```swift
        case .s3:
            // Placeholder; replaced with the real S3Uploader wiring in M2b Task 8.
            throw UploadError.unsupported("S3 upload not wired yet")
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `scripts/remote.sh test 2>&1 | tail -30`
Expected: PASS — the full suite builds and `S3ConfigTests` passes.

- [ ] **Step 7: Commit**

```bash
git add Sources/SXCore/Upload/S3Config.swift Sources/SXCore/Upload/UploadSettings.swift Sources/SXApp/UploadService.swift Tests/SXCoreTests/S3ConfigTests.swift
git commit -m "Add S3Config model and destination wiring"
```

---

### Task 2: SigV4 signer

**Files:**
- Create: `Sources/SXCore/Upload/SigV4Signer.swift`
- Test: `Tests/SXCoreTests/SigV4SignerTests.swift`

**Interfaces:**
- Produces:
  - `SigV4Signer.authorizationHeader(method:canonicalURI:canonicalQuery:signedHeaders:payloadHash:region:service:accessKeyID:secretAccessKey:timestamp:) -> String` — injects `x-amz-date` from `timestamp`; returns the full `Authorization` header value.
  - `SigV4Signer.amzDate(_:) -> String` (`yyyyMMdd'T'HHmmss'Z'`, UTC) and `SigV4Signer.dateStamp(_:) -> String` (`yyyyMMdd`, UTC).
  - internal `SigV4Signer.canonicalRequest(...)` (visible to tests via `@testable`).
- Consumes: CryptoKit.

**Reference:** validated against the AWS SigV4 `get-vanilla` test vector. Access key `AKIDEXAMPLE`, secret `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY`, region `us-east-1`, service `service`, timestamp `20150830T123600Z`, empty payload. Expected `Authorization`:
`AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31`

- [ ] **Step 1: Write the failing test**

Create `Tests/SXCoreTests/SigV4SignerTests.swift`:

```swift
import Foundation
import Testing
@testable import SXCore

@Suite struct SigV4SignerTests {
    /// 2015-08-30T12:36:00Z as a Date.
    private var vectorDate: Date {
        var c = DateComponents()
        c.year = 2015; c.month = 8; c.day = 30
        c.hour = 12; c.minute = 36; c.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    private let emptyPayloadHash =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    @Test func amzDateAndStampAreUTCFormatted() {
        #expect(SigV4Signer.amzDate(vectorDate) == "20150830T123600Z")
        #expect(SigV4Signer.dateStamp(vectorDate) == "20150830")
    }

    @Test func canonicalRequestMatchesGetVanillaVector() {
        let cr = SigV4Signer.canonicalRequest(
            method: "GET", canonicalURI: "/", canonicalQuery: "",
            signedHeaders: ["host": "example.amazonaws.com",
                            "x-amz-date": "20150830T123600Z"],
            payloadHash: emptyPayloadHash)
        let expected = """
        GET
        /

        host:example.amazonaws.com
        x-amz-date:20150830T123600Z

        host;x-amz-date
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        """
        #expect(cr == expected)
    }

    @Test func authorizationHeaderMatchesGetVanillaVector() {
        let auth = SigV4Signer.authorizationHeader(
            method: "GET", canonicalURI: "/", canonicalQuery: "",
            signedHeaders: ["host": "example.amazonaws.com"],
            payloadHash: emptyPayloadHash,
            region: "us-east-1", service: "service",
            accessKeyID: "AKIDEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            timestamp: vectorDate)
        #expect(auth == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/remote.sh test 2>&1 | tail -30`
Expected: FAIL — `cannot find 'SigV4Signer' in scope`.

- [ ] **Step 3: Implement the signer**

Create `Sources/SXCore/Upload/SigV4Signer.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/remote.sh test 2>&1 | tail -30`
Expected: PASS — all three `SigV4SignerTests` pass (proves the HMAC chain, formatting, and canonicalization against the published vector).

- [ ] **Step 5: Commit**

```bash
git add Sources/SXCore/Upload/SigV4Signer.swift Tests/SXCoreTests/SigV4SignerTests.swift
git commit -m "Add hand-rolled SigV4 signer (validated against get-vanilla vector)"
```

---

### Task 3: S3 request builder + result URL

**Files:**
- Create: `Sources/SXCore/Upload/S3RequestBuilder.swift`
- Test: `Tests/SXCoreTests/S3RequestBuilderTests.swift`

**Interfaces:**
- Produces:
  - `SigV4Credentials { accessKeyID, secretAccessKey }` (`Sendable`, `Equatable`).
  - `S3RequestBuilder.build(config:credentials:file:now:) throws -> PreparedRequest` — a signed `PUT`. The returned `headers` include `Authorization`, `x-amz-date`, `x-amz-content-sha256`, and `x-amz-acl` (when configured); `host` is intentionally omitted (URLSession sets it from the URL). `contentType` carries the file MIME and is deliberately NOT signed.
  - `S3RequestBuilder.objectKey(config:filename:) -> String`.
  - `S3RequestBuilder.resultURL(config:filename:) -> String`.
- Consumes: `S3Config`, `SigV4Signer`, `FilePart`, `PreparedRequest`, `HTTPMethod`, `UploadError`, CryptoKit.

- [ ] **Step 1: Write the failing test**

Create `Tests/SXCoreTests/S3RequestBuilderTests.swift`:

```swift
import Foundation
import CryptoKit
import Testing
@testable import SXCore

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/remote.sh test 2>&1 | tail -30`
Expected: FAIL — `cannot find 'S3RequestBuilder' in scope` / `cannot find 'SigV4Credentials'`.

- [ ] **Step 3: Implement the builder**

Create `Sources/SXCore/Upload/S3RequestBuilder.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/remote.sh test 2>&1 | tail -30`
Expected: PASS — all `S3RequestBuilderTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SXCore/Upload/S3RequestBuilder.swift Tests/SXCoreTests/S3RequestBuilderTests.swift
git commit -m "Add S3 request builder (SigV4-signed PUT + result URL)"
```

---

### Task 4: S3 credential vault

**Files:**
- Create: `Sources/SXCore/Upload/S3Credentials.swift`
- Test: `Tests/SXCoreTests/S3CredentialsTests.swift`

**Interfaces:**
- Produces:
  - `S3Credentials.store(accessKeyID:secretAccessKey:id:into:) throws`
  - `S3Credentials.load(id:from:) throws -> SigV4Credentials` (throws `UploadError.missingCredential` if either is absent)
  - `S3Credentials.purge(id:from:) throws`
  - Accounts namespaced `<id>/s3/accessKeyID` and `<id>/s3/secretAccessKey`.
- Consumes: `CredentialStore`, `SigV4Credentials`, `UploadError`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SXCoreTests/S3CredentialsTests.swift`:

```swift
import Foundation
import Testing
@testable import SXCore

private final class DictCredentialStore: CredentialStore, @unchecked Sendable {
    var store: [String: String] = [:]
    func secret(for account: String) throws -> String? { store[account] }
    func setSecret(_ value: String, for account: String) throws { store[account] = value }
    func deleteSecret(for account: String) throws { store[account] = nil }
}

@Suite struct S3CredentialsTests {
    @Test func storeThenLoadRoundTrips() throws {
        let creds = DictCredentialStore()
        try S3Credentials.store(accessKeyID: "AK", secretAccessKey: "SK", id: "d1", into: creds)
        let loaded = try S3Credentials.load(id: "d1", from: creds)
        #expect(loaded == SigV4Credentials(accessKeyID: "AK", secretAccessKey: "SK"))
        // Namespaced accounts, nothing global.
        #expect(creds.store["d1/s3/accessKeyID"] == "AK")
        #expect(creds.store["d1/s3/secretAccessKey"] == "SK")
    }

    @Test func loadThrowsWhenSecretMissing() throws {
        let creds = DictCredentialStore()
        try creds.setSecret("AK", for: "d1/s3/accessKeyID")   // access key only
        #expect(throws: UploadError.self) {
            _ = try S3Credentials.load(id: "d1", from: creds)
        }
    }

    @Test func purgeDeletesBothAccounts() throws {
        let creds = DictCredentialStore()
        try S3Credentials.store(accessKeyID: "AK", secretAccessKey: "SK", id: "d1", into: creds)
        try S3Credentials.purge(id: "d1", from: creds)
        #expect(creds.store.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/remote.sh test 2>&1 | tail -30`
Expected: FAIL — `cannot find 'S3Credentials' in scope`.

- [ ] **Step 3: Implement the vault**

Create `Sources/SXCore/Upload/S3Credentials.swift`:

```swift
import Foundation

/// Moves S3 secret material in/out of a `CredentialStore`, namespaced under
/// `<id>/s3/*`, so nothing sensitive is written to settings.json.
public enum S3Credentials {
    private static func account(_ id: String, _ key: String) -> String { "\(id)/s3/\(key)" }

    public static func store(accessKeyID: String, secretAccessKey: String,
                             id: String, into credentials: CredentialStore) throws {
        try credentials.setSecret(accessKeyID, for: account(id, "accessKeyID"))
        try credentials.setSecret(secretAccessKey, for: account(id, "secretAccessKey"))
    }

    public static func load(id: String, from credentials: CredentialStore) throws -> SigV4Credentials {
        guard let ak = try credentials.secret(for: account(id, "accessKeyID")) else {
            throw UploadError.missingCredential(account(id, "accessKeyID"))
        }
        guard let sk = try credentials.secret(for: account(id, "secretAccessKey")) else {
            throw UploadError.missingCredential(account(id, "secretAccessKey"))
        }
        return SigV4Credentials(accessKeyID: ak, secretAccessKey: sk)
    }

    public static func purge(id: String, from credentials: CredentialStore) throws {
        try credentials.deleteSecret(for: account(id, "accessKeyID"))
        try credentials.deleteSecret(for: account(id, "secretAccessKey"))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/remote.sh test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SXCore/Upload/S3Credentials.swift Tests/SXCoreTests/S3CredentialsTests.swift
git commit -m "Add S3 credential vault (namespaced Keychain accounts)"
```

---

### Task 5: S3Uploader

**Files:**
- Create: `Sources/SXUpload/S3Uploader.swift`
- Test: `Tests/SXUploadTests/S3UploaderTests.swift`

**Interfaces:**
- Produces: `S3Uploader(config:credentials:http:now:)` conforming to `Uploader`. Sends the signed `PUT`; on 2xx returns `UploadResult(url: resultURL)`; on non-2xx throws `UploadError.http(status:body:)`.
- Consumes: `S3Config`, `SigV4Credentials`, `S3RequestBuilder`, `HTTPClient`, `HTTPResponse`, `FilePart`, `UploadResult`, `UploadError`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SXUploadTests/S3UploaderTests.swift`:

```swift
import Foundation
import Testing
@testable import SXUpload
import SXCore

private final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    var response: HTTPResponse
    var lastRequest: PreparedRequest?
    init(response: HTTPResponse) { self.response = response }
    func send(_ request: PreparedRequest) async throws -> HTTPResponse {
        lastRequest = request
        return response
    }
}

@Suite struct S3UploaderTests {
    private let creds = SigV4Credentials(accessKeyID: "AK", secretAccessKey: "SK")
    private var config: S3Config {
        S3Config(region: "us-east-1", endpoint: "s3.us-east-1.amazonaws.com",
                 bucket: "shots", objectPrefix: "screens/")
    }
    private func png() -> FilePart {
        FilePart(fieldName: "file", filename: "shot.png", mimeType: "image/png", data: Data([1, 2, 3]))
    }
    private var fixedNow: @Sendable () -> Date { { Date(timeIntervalSince1970: 1_440_938_160) } }

    @Test func successReturnsDerivedResultURL() async throws {
        let mock = MockHTTPClient(response: HTTPResponse(status: 200, headers: [:], body: Data()))
        let uploader = S3Uploader(config: config, credentials: creds, http: mock, now: fixedNow)
        let result = try await uploader.upload(png())
        #expect(result.url == "https://shots.s3.us-east-1.amazonaws.com/screens/shot.png")
        #expect(mock.lastRequest?.method == .put)
        #expect(mock.lastRequest?.headers["Authorization"] != nil)
    }

    @Test func non2xxThrowsHTTPError() async {
        let mock = MockHTTPClient(response: HTTPResponse(status: 403, headers: [:],
                                                         body: Data("AccessDenied".utf8)))
        let uploader = S3Uploader(config: config, credentials: creds, http: mock, now: fixedNow)
        await #expect(throws: UploadError.self) {
            _ = try await uploader.upload(png())
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/remote.sh test 2>&1 | tail -30`
Expected: FAIL — `cannot find 'S3Uploader' in scope`.

- [ ] **Step 3: Implement S3Uploader**

Create `Sources/SXUpload/S3Uploader.swift`:

```swift
import Foundation
import SXCore

/// S3-compatible uploader: SigV4-signed `PUT` object, result URL derived from
/// config (no response parsing — S3 returns an empty 200 body on success).
public struct S3Uploader: Uploader {
    private let config: S3Config
    private let credentials: SigV4Credentials
    private let http: HTTPClient
    private let now: @Sendable () -> Date

    public init(config: S3Config, credentials: SigV4Credentials, http: HTTPClient,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.credentials = credentials
        self.http = http
        self.now = now
    }

    public func upload(_ file: FilePart) async throws -> UploadResult {
        let request = try S3RequestBuilder.build(config: config, credentials: credentials,
                                                 file: file, now: now())
        let response = try await http.send(request)
        guard (200..<300).contains(response.status) else {
            throw UploadError.http(status: response.status,
                                   body: String(data: response.body, encoding: .utf8) ?? "")
        }
        return UploadResult(url: S3RequestBuilder.resultURL(config: config, filename: file.filename))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/remote.sh test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SXUpload/S3Uploader.swift Tests/SXUploadTests/S3UploaderTests.swift
git commit -m "Add S3Uploader (signed PUT, config-derived result URL)"
```

---

### Task 6: UploadSettings management helpers

**Files:**
- Create: `Sources/SXCore/Upload/UploadSettings+Management.swift`
- Test: `Tests/SXCoreTests/UploadSettingsManagementTests.swift`

**Interfaces:**
- Produces (all pure, non-mutating, return a new `UploadSettings`):
  - `UploadSettings.addingOrUpdating(_ destination:) -> UploadSettings` (replace by id, else append)
  - `UploadSettings.removing(id:) -> UploadSettings` (also clears `activeDestinationID` when it matches)
  - `UploadSettings.settingActive(id:) -> UploadSettings`
- Consumes: `UploadSettings`, `UploadDestination`.

- [ ] **Step 1: Write the failing test**

Create `Tests/SXCoreTests/UploadSettingsManagementTests.swift`:

```swift
import Foundation
import Testing
@testable import SXCore

@Suite struct UploadSettingsManagementTests {
    private func dest(_ id: String, _ name: String) -> UploadDestination {
        UploadDestination(id: id, name: name, kind: .imgur, imgurClientID: "cid")
    }

    @Test func addingAppendsNewAndReplacesExisting() {
        var s = UploadSettings.disabled
        s = s.addingOrUpdating(dest("a", "A"))
        s = s.addingOrUpdating(dest("b", "B"))
        #expect(s.destinations.map(\.id) == ["a", "b"])
        s = s.addingOrUpdating(dest("a", "A2"))            // replace, not append
        #expect(s.destinations.count == 2)
        #expect(s.destinations.first { $0.id == "a" }?.name == "A2")
    }

    @Test func removingDropsAndClearsActiveWhenItMatches() {
        var s = UploadSettings(uploadAfterCapture: true, activeDestinationID: "a",
                               destinations: [dest("a", "A"), dest("b", "B")])
        s = s.removing(id: "a")
        #expect(s.destinations.map(\.id) == ["b"])
        #expect(s.activeDestinationID == nil)              // active pointed at the removed one
    }

    @Test func removingKeepsActiveWhenDifferent() {
        var s = UploadSettings(uploadAfterCapture: true, activeDestinationID: "b",
                               destinations: [dest("a", "A"), dest("b", "B")])
        s = s.removing(id: "a")
        #expect(s.activeDestinationID == "b")
    }

    @Test func settingActiveUpdatesThePointer() {
        let s = UploadSettings.disabled.settingActive(id: "x")
        #expect(s.activeDestinationID == "x")
        #expect(s.settingActive(id: nil).activeDestinationID == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/remote.sh test 2>&1 | tail -30`
Expected: FAIL — `value of type 'UploadSettings' has no member 'addingOrUpdating'`.

- [ ] **Step 3: Implement the helpers**

Create `Sources/SXCore/Upload/UploadSettings+Management.swift`:

```swift
import Foundation

public extension UploadSettings {
    /// Replace the destination sharing `destination.id`, or append it if new.
    func addingOrUpdating(_ destination: UploadDestination) -> UploadSettings {
        var copy = self
        if let idx = copy.destinations.firstIndex(where: { $0.id == destination.id }) {
            copy.destinations[idx] = destination
        } else {
            copy.destinations.append(destination)
        }
        return copy
    }

    /// Remove a destination by id; clears the active selection if it pointed there.
    func removing(id: String) -> UploadSettings {
        var copy = self
        copy.destinations.removeAll { $0.id == id }
        if copy.activeDestinationID == id { copy.activeDestinationID = nil }
        return copy
    }

    /// Set (or clear, with `nil`) the active destination.
    func settingActive(id: String?) -> UploadSettings {
        var copy = self
        copy.activeDestinationID = id
        return copy
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/remote.sh test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SXCore/Upload/UploadSettings+Management.swift Tests/SXCoreTests/UploadSettingsManagementTests.swift
git commit -m "Add UploadSettings add/remove/set-active helpers"
```

---

### Task 7: SecretVault.purge (custom uploader)

**Files:**
- Modify: `Sources/SXCore/Upload/SecretVault.swift`
- Test: `Tests/SXCoreTests/SecretVaultTests.swift` (add cases to the existing suite)

**Interfaces:**
- Produces: `SecretVault.purge(_ config:id:from:) throws` — deletes every namespaced Keychain account a stripped config occupies (headers/arguments/parameters sentinel slots + the data body slot).
- Consumes: `SecretVault.account(id:surface:key:)` (existing private helper), `CredentialStore`.

- [ ] **Step 1: Write the failing test**

Add to the existing `@Suite struct SecretVaultTests` in `Tests/SXCoreTests/SecretVaultTests.swift`:

```swift
    @Test func purgeDeletesEveryStoredSecretAccount() throws {
        let creds = DictCredentialStore()
        let stripped = try SecretVault.strip(configWithSecretsEverywhere(), id: "d1", into: creds)
        #expect(!creds.store.isEmpty)                 // secrets were stored
        try SecretVault.purge(stripped, id: "d1", from: creds)
        #expect(creds.store.isEmpty)                  // every namespaced account removed
    }
```

(`configWithSecretsEverywhere()` and `DictCredentialStore` already exist in this test file.)

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/remote.sh test 2>&1 | tail -30`
Expected: FAIL — `type 'SecretVault' has no member 'purge'`.

- [ ] **Step 3: Implement purge**

Add to `Sources/SXCore/Upload/SecretVault.swift` (after `inject`):

```swift
    /// Delete every Keychain account this stripped config's secrets occupy.
    /// Call on destination removal so no orphaned secrets linger.
    public static func purge(_ config: CustomUploaderConfig, id: String,
                             from credentials: CredentialStore) throws {
        for (key, value) in config.headers where value == sentinel {
            try credentials.deleteSecret(for: account(id: id, surface: "header", key: key))
        }
        for (key, value) in config.arguments where value == sentinel {
            try credentials.deleteSecret(for: account(id: id, surface: "arg", key: key))
        }
        for (key, value) in config.parameters where value == sentinel {
            try credentials.deleteSecret(for: account(id: id, surface: "param", key: key))
        }
        if config.data == sentinel {
            try credentials.deleteSecret(for: account(id: id, surface: "data", key: "body"))
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/remote.sh test 2>&1 | tail -30`
Expected: PASS — the new case and all existing `SecretVaultTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SXCore/Upload/SecretVault.swift Tests/SXCoreTests/SecretVaultTests.swift
git commit -m "Add SecretVault.purge to clean up secrets on destination removal"
```

---

### Task 8: Destination-management UI + UploadService S3 branch + menu

**Files:**
- Modify: `Sources/SXApp/UploadService.swift` (replace Task-1 `.s3` placeholder with real wiring)
- Create: `Sources/SXApp/DestinationsView.swift` (SwiftUI model + view)
- Create: `Sources/SXApp/DestinationsWindowController.swift`
- Modify: `Sources/SXApp/AppDelegate.swift` (menu item + handler + window controller)

**Interfaces:**
- Consumes: `UploadDestination`, `UploadSettings` (+ management helpers), `S3Config`, `S3Credentials`, `SecretVault.purge`, `S3Uploader`, `SigV4Credentials`, `SettingsStore`, `CredentialStore`, `KeychainCredentialStore`, `AppLog`.
- Produces: a "Manage Destinations…" menu action opening a window to list/add/remove destinations and choose the active one; `UploadService.uploader(for:)` resolving `.s3` destinations.

**This is a UI + wiring task — no unit tests.** Gate: `swift build` succeeds; the underlying logic is already covered by Tasks 4–7. Verified interactively in the Mac smoke checklist below.

- [ ] **Step 1: Wire the S3 branch into UploadService**

In `Sources/SXApp/UploadService.swift`, replace the placeholder `.s3` branch added in Task 1 with:

```swift
        case .s3:
            guard let config = destination.s3Config else {
                throw UploadError.unsupported("Destination has no S3 config")
            }
            let creds = try S3Credentials.load(id: destination.id, from: credentials)
            return S3Uploader(config: config, credentials: creds, http: http)
```

- [ ] **Step 2: Build the destinations model + view**

Create `Sources/SXApp/DestinationsView.swift`:

```swift
import SwiftUI
import SXCore
import SXUpload

@MainActor
final class DestinationsModel: ObservableObject {
    @Published var settings: UploadSettings
    private let store: SettingsStore
    private let credentials: CredentialStore
    private let onChange: () -> Void

    init(store: SettingsStore, credentials: CredentialStore, onChange: @escaping () -> Void) {
        self.store = store
        self.credentials = credentials
        self.onChange = onChange
        self.settings = store.loadOrDefault().0.upload
    }

    /// Reload full settings, mutate `.upload`, persist, and refresh the menu.
    private func persist(_ mutate: (inout AppSettings) -> Void) {
        var (all, _) = store.loadOrDefault()
        mutate(&all)
        do {
            try store.save(all)
            settings = all.upload
            onChange()
        } catch {
            AppLog.log("Destinations: save failed: \(error)")
        }
    }

    func setActive(_ id: String) {
        persist { $0.upload = $0.upload.settingActive(id: id) }
    }

    func remove(_ destination: UploadDestination) {
        // Purge Keychain secrets BEFORE dropping the destination so nothing is orphaned.
        do {
            switch destination.kind {
            case .customUploader:
                if let cfg = destination.customUploader {
                    try SecretVault.purge(cfg, id: destination.id, from: credentials)
                }
            case .s3:
                try S3Credentials.purge(id: destination.id, from: credentials)
            case .imgur:
                break
            }
        } catch {
            AppLog.log("Destinations: secret purge failed for \(destination.id): \(error)")
        }
        persist { $0.upload = $0.upload.removing(id: destination.id) }
    }

    func addImgur(name: String, clientID: String) {
        let dest = UploadDestination(id: UUID().uuidString,
                                     name: name.isEmpty ? "Imgur" : name,
                                     kind: .imgur, imgurClientID: clientID)
        persist { $0.upload = $0.upload.addingOrUpdating(dest).settingActive(id: dest.id) }
    }

    func addS3(name: String, region: String, endpoint: String, bucket: String, prefix: String,
               accessKeyID: String, secretAccessKey: String, pathStyle: Bool,
               acl: String, customDomain: String) {
        let id = UUID().uuidString
        do {
            try S3Credentials.store(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
                                    id: id, into: credentials)
        } catch {
            AppLog.log("Destinations: storing S3 credentials failed: \(error)")
            return
        }
        let config = S3Config(region: region, endpoint: endpoint, bucket: bucket,
                              objectPrefix: prefix,
                              addressingStyle: pathStyle ? .path : .virtualHost,
                              acl: acl.isEmpty ? nil : acl,
                              customDomain: customDomain.isEmpty ? nil : customDomain)
        let dest = UploadDestination(id: id, name: name.isEmpty ? "S3" : name,
                                     kind: .s3, s3Config: config)
        persist { $0.upload = $0.upload.addingOrUpdating(dest).settingActive(id: id) }
    }

    func kindLabel(_ kind: UploadDestinationKind) -> String {
        switch kind {
        case .customUploader: return "Custom (.sxcu)"
        case .imgur: return "Imgur"
        case .s3: return "S3"
        }
    }
}

struct DestinationsView: View {
    @ObservedObject var model: DestinationsModel
    @State private var showAddS3 = false
    @State private var showAddImgur = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Destinations").font(.headline)
            if model.settings.destinations.isEmpty {
                Text("No destinations yet. Add one below or import a .sxcu from the menu.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                List {
                    ForEach(model.settings.destinations) { dest in
                        HStack {
                            Image(systemName: model.settings.activeDestinationID == dest.id
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(.tint)
                                .onTapGesture { model.setActive(dest.id) }
                            VStack(alignment: .leading) {
                                Text(dest.name)
                                Text(model.kindLabel(dest.kind))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { model.remove(dest) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.setActive(dest.id) }
                    }
                }
            }
            HStack {
                Button("Add S3…") { showAddS3 = true }
                Button("Add Imgur…") { showAddImgur = true }
                Spacer()
            }
        }
        .padding()
        .sheet(isPresented: $showAddS3) { AddS3Sheet(model: model, isPresented: $showAddS3) }
        .sheet(isPresented: $showAddImgur) { AddImgurSheet(model: model, isPresented: $showAddImgur) }
    }
}

private struct AddS3Sheet: View {
    @ObservedObject var model: DestinationsModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var region = "us-east-1"
    @State private var endpoint = "s3.us-east-1.amazonaws.com"
    @State private var bucket = ""
    @State private var prefix = ""
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var pathStyle = false
    @State private var acl = ""
    @State private var customDomain = ""

    var body: some View {
        VStack(alignment: .leading) {
            Text("Add S3 Destination").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("Region", text: $region)
                TextField("Endpoint (host, no bucket)", text: $endpoint)
                TextField("Bucket", text: $bucket)
                TextField("Object prefix (optional)", text: $prefix)
                TextField("Access Key ID", text: $accessKeyID)
                SecureField("Secret Access Key", text: $secretAccessKey)
                Toggle("Path-style addressing", isOn: $pathStyle)
                TextField("ACL (optional, e.g. public-read)", text: $acl)
                TextField("Custom domain (optional)", text: $customDomain)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Add") {
                    model.addS3(name: name, region: region, endpoint: endpoint, bucket: bucket,
                                prefix: prefix, accessKeyID: accessKeyID,
                                secretAccessKey: secretAccessKey, pathStyle: pathStyle,
                                acl: acl, customDomain: customDomain)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bucket.isEmpty || endpoint.isEmpty || accessKeyID.isEmpty
                          || secretAccessKey.isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

private struct AddImgurSheet: View {
    @ObservedObject var model: DestinationsModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var clientID = ""

    var body: some View {
        VStack(alignment: .leading) {
            Text("Add Imgur Destination").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("Client ID", text: $clientID)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Add") {
                    model.addImgur(name: name, clientID: clientID)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(clientID.isEmpty)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
```

- [ ] **Step 3: Add the window controller**

Create `Sources/SXApp/DestinationsWindowController.swift`:

```swift
import AppKit
import SwiftUI
import SXCore

@MainActor
final class DestinationsWindowController {
    private var window: NSWindow?
    private let store: SettingsStore
    private let credentials: CredentialStore
    private let onChange: () -> Void

    init(store: SettingsStore, credentials: CredentialStore, onChange: @escaping () -> Void) {
        self.store = store
        self.credentials = credentials
        self.onChange = onChange
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = DestinationsModel(store: store, credentials: credentials, onChange: onChange)
        let hosting = NSHostingController(rootView: DestinationsView(model: model))
        let w = NSWindow(contentViewController: hosting)
        w.title = "Manage Destinations"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 480, height: 440))
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}
```

- [ ] **Step 4: Wire the menu item into AppDelegate**

In `Sources/SXApp/AppDelegate.swift`:

Add stored properties near the top of the class:

```swift
    private var destinationsWindow: DestinationsWindowController?
```

In `applicationDidFinishLaunching`, after `self.coordinator = coordinator`, create the window controller:

```swift
        destinationsWindow = DestinationsWindowController(
            store: store, credentials: KeychainCredentialStore(),
            onChange: { [weak self] in self?.rebuildMenu() })
```

In `buildMenu()`, add the item right after the `Import .sxcu…` item:

```swift
        menu.addItem(menuItem("Manage Destinations…", #selector(manageDestinations)))
```

Add the handler alongside the other `@objc` menu handlers:

```swift
    @objc private func manageDestinations() { destinationsWindow?.show() }
```

- [ ] **Step 5: Build to verify it compiles**

Run: `scripts/remote.sh build 2>&1 | tail -30`
Expected: build succeeds with no errors.

- [ ] **Step 6: Run the full test suite (guard against regressions)**

Run: `scripts/remote.sh test 2>&1 | tail -20`
Expected: PASS — no existing tests regressed.

- [ ] **Step 7: Commit**

```bash
git add Sources/SXApp/UploadService.swift Sources/SXApp/DestinationsView.swift Sources/SXApp/DestinationsWindowController.swift Sources/SXApp/AppDelegate.swift
git commit -m "Add destination-management UI and wire S3 uploader"
```

---

### Task 9: HistoryStore.all + search

**Files:**
- Modify: `Sources/SXCore/History/HistoryStore.swift` (extract a shared row reader; add `all` + `search`)
- Test: `Tests/SXCoreTests/HistoryStoreTests.swift` (add cases)

**Interfaces:**
- Produces:
  - `HistoryStore.all(limit:) throws -> [HistoryEntry]` (newest first — alias semantics of `recent`).
  - `HistoryStore.search(matching:limit:) throws -> [HistoryEntry]` — case-insensitive `LIKE` over `file_path`, `url`, `destination`; empty/whitespace query returns `recent(limit:)`.
- Refactor: extract `private func readRows(_:) throws -> [HistoryEntry]` and use it from both `recent` and `search` (DRY; do not duplicate the row-mapping block).

- [ ] **Step 1: Write the failing test**

Add to the existing history test suite in `Tests/SXCoreTests/HistoryStoreTests.swift` (reuse whatever temp-file/store setup the file already uses; a self-contained variant is shown here):

```swift
    @Test func searchMatchesUrlAndDestinationAndEmptyReturnsAll() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sx-history-\(UUID().uuidString).sqlite")
        let store = try HistoryStore(fileURL: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try store.insert(HistoryEntry(id: "1", capturedAt: Date(timeIntervalSince1970: 100),
                                      filePath: "/tmp/alpha.png", url: "https://cdn/alpha.png",
                                      deletionURL: nil, destinationName: "S3", uploadFailed: false))
        try store.insert(HistoryEntry(id: "2", capturedAt: Date(timeIntervalSince1970: 200),
                                      filePath: "/tmp/beta.png", url: "https://i.imgur.com/beta",
                                      deletionURL: nil, destinationName: "Imgur", uploadFailed: false))

        #expect(try store.search(matching: "imgur", limit: 50).map(\.id) == ["2"])
        #expect(try store.search(matching: "S3", limit: 50).map(\.id) == ["1"])
        #expect(try store.search(matching: "alpha", limit: 50).map(\.id) == ["1"])
        // Empty query falls back to recent() (newest first).
        #expect(try store.search(matching: "   ", limit: 50).map(\.id) == ["2", "1"])
        #expect(try store.all(limit: 50).map(\.id) == ["2", "1"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/remote.sh test 2>&1 | tail -30`
Expected: FAIL — `value of type 'HistoryStore' has no member 'search'`.

- [ ] **Step 3: Refactor the row reader and add the queries**

In `Sources/SXCore/History/HistoryStore.swift`, add a shared reader in the `// MARK: - Helpers` section:

```swift
    /// Read every row the prepared statement yields, distinguishing a clean end
    /// (SQLITE_DONE) from a genuine mid-scan read error (fail loud).
    private func readRows(_ stmt: OpaquePointer?) throws -> [HistoryEntry] {
        var rows: [HistoryEntry] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            rows.append(HistoryEntry(
                id: text(stmt, 0) ?? "",
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                filePath: text(stmt, 2),
                url: text(stmt, 3),
                deletionURL: text(stmt, 4),
                destinationName: text(stmt, 5),
                uploadFailed: sqlite3_column_int(stmt, 6) != 0))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw HistoryStoreError.exec(lastError) }
        return rows
    }
```

Replace the row-reading loop in `recent(limit:)` so it ends with:

```swift
        sqlite3_bind_int(stmt, 1, Int32(min(max(limit, 0), Int(Int32.max))))  // clamp: never trap
        return try readRows(stmt)
```

(Remove `recent`'s old inline `var rows` / `while` / `guard rc == SQLITE_DONE` block — `readRows` now owns it.)

Add the two public queries after `recent(limit:)`:

```swift
    /// Newest-first, capped at `limit`. Alias of `recent` for browser call sites.
    public func all(limit: Int) throws -> [HistoryEntry] {
        try recent(limit: limit)
    }

    /// Case-insensitive substring match across file path, URL, and destination.
    /// An empty/whitespace query returns `recent(limit:)`.
    public func search(matching query: String, limit: Int) throws -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try recent(limit: limit) }
        let sql = """
            SELECT id, captured_at, file_path, url, deletion_url, destination, upload_failed
            FROM history
            WHERE file_path LIKE ? OR url LIKE ? OR destination LIKE ?
            ORDER BY captured_at DESC LIMIT ?;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        let pattern = "%\(trimmed)%"
        bindText(stmt, 1, pattern)
        bindText(stmt, 2, pattern)
        bindText(stmt, 3, pattern)
        sqlite3_bind_int(stmt, 4, Int32(min(max(limit, 0), Int(Int32.max))))
        return try readRows(stmt)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/remote.sh test 2>&1 | tail -30`
Expected: PASS — new cases and all existing `HistoryStoreTests` pass (the `recent` refactor preserves behavior).

- [ ] **Step 5: Commit**

```bash
git add Sources/SXCore/History/HistoryStore.swift Tests/SXCoreTests/HistoryStoreTests.swift
git commit -m "Add history all()/search() queries with shared row reader"
```

---

### Task 10: History browser UI + menu

**Files:**
- Create: `Sources/SXApp/HistoryView.swift` (SwiftUI model + view)
- Create: `Sources/SXApp/HistoryWindowController.swift`
- Modify: `Sources/SXApp/AppDelegate.swift` (retain the history store; add menu item + handler)

**Interfaces:**
- Consumes: `HistoryStore` (`all`/`search`/`delete`), `HistoryEntry`, `HTTPClient`, `URLSessionHTTPClient`, `PreparedRequest`, `AppLog`.
- Produces: a "History…" menu action opening a window that lists captures with search, thumbnail, and per-row Copy URL / Open / Reveal / Delete (Delete removes the row and best-effort invokes the remote deletion URL when present).

**This is a UI + wiring task — no unit tests.** Gate: `swift build` succeeds; query logic covered by Task 9. Verified in the Mac smoke checklist.

**Simplification (flag for review):** the spec (§3.3) calls for a "thumbnail grid." This implements a searchable **list with a leading thumbnail** per row — the simpler layout that delivers the same actions (browse, search, copy, open, reveal, delete) for a daily-driver. A true grid is deferred polish, not a v1 blocker.

- [ ] **Step 1: Build the history model + view**

Create `Sources/SXApp/HistoryView.swift`:

```swift
import AppKit
import SwiftUI
import SXCore
import SXUpload

@MainActor
final class HistoryModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    @Published var query: String = "" { didSet { reload() } }
    private let store: HistoryStore
    private let http: HTTPClient

    init(store: HistoryStore, http: HTTPClient = URLSessionHTTPClient()) {
        self.store = store
        self.http = http
        reload()
    }

    func reload() {
        do {
            entries = query.trimmingCharacters(in: .whitespaces).isEmpty
                ? try store.all(limit: 500)
                : try store.search(matching: query, limit: 500)
        } catch {
            AppLog.log("History: load failed: \(error)")
            entries = []
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func delete(_ entry: HistoryEntry) {
        do { try store.delete(id: entry.id) }
        catch { AppLog.log("History: delete failed for \(entry.id): \(error)") }
        // Best-effort remote deletion; local removal already succeeded.
        if let del = entry.deletionURL, let url = URL(string: del) {
            let http = self.http
            Task {
                do { _ = try await http.send(PreparedRequest(method: .get, url: url.absoluteString)) }
                catch { AppLog.log("History: remote deletion failed for \(entry.id): \(error)") }
            }
        }
        reload()
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search captures", text: $model.query)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(8)
            Divider()
            if model.entries.isEmpty {
                Spacer()
                Text("No captures yet.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(model.entries) { entry in
                    HistoryRow(entry: entry, model: model)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 400)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    @ObservedObject var model: HistoryModel

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(path: entry.filePath)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.url ?? entry.filePath.map { ($0 as NSString).lastPathComponent }
                     ?? "Capture")
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    if let dest = entry.destinationName { Text("· \(dest)") }
                    if entry.uploadFailed { Text("· upload failed").foregroundStyle(.red) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let url = entry.url {
                Button { model.copy(url) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy URL")
                Button { model.open(url) } label: { Image(systemName: "safari") }
                    .buttonStyle(.borderless).help("Open URL")
            }
            if let path = entry.filePath {
                Button { model.reveal(path) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Reveal in Finder")
            }
            Button(role: .destructive) { model.delete(entry) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete")
        }
        .padding(.vertical, 2)
    }
}

private struct Thumbnail: View {
    let path: String?
    var body: some View {
        if let path, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable().aspectRatio(contentMode: .fill)
                .frame(width: 48, height: 36).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: 48, height: 36)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }
}
```

- [ ] **Step 2: Add the window controller**

Create `Sources/SXApp/HistoryWindowController.swift`:

```swift
import AppKit
import SwiftUI
import SXCore

@MainActor
final class HistoryWindowController {
    private var window: NSWindow?
    private let store: HistoryStore

    init(store: HistoryStore) { self.store = store }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = HistoryModel(store: store)
        let hosting = NSHostingController(rootView: HistoryView(model: model))
        let w = NSWindow(contentViewController: hosting)
        w.title = "History"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 560, height: 460))
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }
}
```

- [ ] **Step 3: Wire the menu item into AppDelegate**

In `Sources/SXApp/AppDelegate.swift`:

Add stored properties near the other window/coordinator properties:

```swift
    private var historyStore: HistoryStore?
    private var historyWindow: HistoryWindowController?
```

In `applicationDidFinishLaunching`, after the existing `let historyStore = try? HistoryStore(...)` line and its `nil` log, retain it:

```swift
        self.historyStore = historyStore
```

In `buildMenu()`, add a separator + item after the `Upload After Capture` toggle (before the final separator + Quit):

```swift
        menu.addItem(.separator())
        menu.addItem(menuItem("History…", #selector(showHistory)))
```

Add the handler with the other `@objc` handlers:

```swift
    @objc private func showHistory() {
        guard let store = historyStore else {
            effects.notify(title: "History unavailable",
                           body: "The history database could not be opened.", fileURL: nil)
            return
        }
        if historyWindow == nil { historyWindow = HistoryWindowController(store: store) }
        historyWindow?.show()
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `scripts/remote.sh build 2>&1 | tail -30`
Expected: build succeeds.

- [ ] **Step 5: Run the full test suite (guard against regressions)**

Run: `scripts/remote.sh test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SXApp/HistoryView.swift Sources/SXApp/HistoryWindowController.swift Sources/SXApp/AppDelegate.swift
git commit -m "Add history browser window (search, thumbnails, copy/open/reveal/delete)"
```

---

### Task 11: Docs — porting map + README

**Files:**
- Modify: `docs/porting-map.md` (add rows for the new Swift types → ShareX classes)
- Modify: `README.md` (feature list)

**Interfaces:** none (documentation only).

- [ ] **Step 1: Read the current docs**

Run: `cat docs/porting-map.md README.md`
Note the existing table format in `porting-map.md` and the feature-list section in `README.md`.

- [ ] **Step 2: Add porting-map rows**

Append rows to the mapping table in `docs/porting-map.md` matching the existing column format (Swift type → ShareX reference). Add entries for:

- `SigV4Signer` → `ShareX.UploadersLib` AWS SigV4 signing (`AmazonS3Uploader` request signing).
- `S3RequestBuilder` / `S3Uploader` → `ShareX.UploadersLib.FileUploaders.AmazonS3`.
- `S3Config` / `S3Credentials` → `AmazonS3Settings`.
- `DestinationsView` / `DestinationsModel` → ShareX uploaders-config UI (`UploadersConfigForm`).
- `HistoryView` / `HistoryModel` → ShareX `HistoryForm` / `HistoryManager`.
- `SecretVault.purge` / `UploadSettings` management helpers → ShareX uploader config persistence.

(If `docs/porting-map.md` does not exist, create it with a short header and a table using the columns the spec describes: Swift type, ShareX class, notes.)

- [ ] **Step 3: Update the README feature list**

In `README.md`, extend the features/uploaders section to note: S3-compatible uploads (hand-rolled SigV4; AWS/R2/MinIO/B2; path- and virtual-host addressing; optional ACL; custom result-URL domain), a searchable history browser, and destination management (add/remove/select destinations, import `.sxcu`) — with credentials stored in the Keychain, never in `settings.json`.

- [ ] **Step 4: Commit**

```bash
git add docs/porting-map.md README.md
git commit -m "Document S3, history browser, and destination management"
```

---

## Self-Review

**Spec coverage (§3.3 Upload):**
- S3-compatible, hand-rolled SigV4, custom endpoints (R2/MinIO/B2), path/virtual-host addressing, optional ACL header, custom result-URL → Tasks 2–5, 8. ✅
- Credentials in Keychain; nothing secret in settings.json → Tasks 4, 7, 8 (S3Credentials + SecretVault.purge; UI stores via vault). ✅
- History SQLite window: search, thumbnail, copy-URL, open, reveal, delete (incl. remote deletion-URL) → Tasks 9, 10. ✅
- Destination management (create/remove/select without hand-editing JSON) → Tasks 6, 8. ✅
- SFTP/FTP and Imgur OAuth remain deferred (M5 / post-v1) — correctly out of scope. ✅

**Global constraints:** no new dependencies (CryptoKit/SwiftUI/URLSession/Security/SQLite only; `Package.swift` untouched); Swift 6 concurrency (per-call formatters, `@MainActor` UI, `Sendable` closures); fail-loud (all catch sites log or notify); local-first capture path untouched; secrets Keychain-only. ✅

**Type consistency:** `SigV4Credentials` defined in Task 3, consumed in Tasks 4/5/8. `S3Config` defined Task 1, consumed Tasks 3/5/8. `UploadSettings` helpers defined Task 6, consumed Task 8. `HistoryStore.all/search` defined Task 9, consumed Task 10. `SecretVault.purge` defined Task 7, consumed Task 8. `.s3` enum case added Task 1 with a placeholder branch, finalized Task 8. ✅

**Placeholder scan:** every code step contains complete code; UI tasks provide full compilable views. The only intentional stub is the Task-1 `.s3` throwing branch, explicitly replaced in Task 8. ✅

## Mac smoke checklist (after Task 10, before finishing the branch)

Run `scripts/remote.sh run` to rebuild + bundle + launch, then verify on the Mac:

1. **Menu:** "Manage Destinations…" and "History…" appear.
2. **Add S3:** open Manage Destinations → Add S3…, fill a real bucket/keys, Add → it appears and becomes active; confirm `settings.json` holds the `S3Config` but **no** access/secret key (grep the file), and the Keychain holds `<id>/s3/*`.
3. **Upload to S3:** with Upload After Capture on and the S3 destination active, capture a region → local file saved (local-first) → URL copied to clipboard → reachable (HTTP 200) → history row recorded.
4. **Add Imgur / import .sxcu:** both still add destinations; selecting the radio changes the active one; menu toggle state stays consistent.
5. **Remove:** delete a destination → it disappears and its Keychain secrets are gone (re-adding generates a fresh id).
6. **History window:** shows captures with thumbnails; search filters; Copy URL / Open / Reveal work; Delete removes the row (and fires the remote deletion URL when present).
