# M2a — Share / Upload (custom uploader + Imgur) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a capture is saved locally, upload it to the active destination (a ShareX `.sxcu` custom uploader or Imgur), copy the resulting URL to the clipboard, notify, and record it in a local history database — the core "capture → share a link" flow.

**Architecture:** A new `SXUpload` SwiftPM target holds the networking layer (URLSession execution + the three provider clients). Pure, testable logic — the `.sxcu` model, response-URL syntax parser, request-body encoding, upload settings, and the SQLite history store — lives in `SXCore` behind protocols, so it is unit-tested without a network. Upload runs as an async stage *after* the existing synchronous local-first pipeline, preserving the "disk before anything else" invariant. Credentials live in the Keychain (a `CredentialStore` protocol in `SXCore`, real `Security`-framework impl in `SXApp`).

**Tech Stack:** Swift 6 (strict concurrency), URLSession, Foundation `JSONSerialization`/`NSRegularExpression`, system `SQLite3`, `Security` (Keychain). No external SwiftPM dependencies (SigV4/S3 and the history browser UI are M2b; SFTP/FTP is M5).

## Global Constraints

- macOS 15+ (`platforms: [.macOS(.v15)]`), Apple Silicon only.
- Bundle ID `org.sharexmac.app`; app display name **ShareX for Mac**; `LSUIElement` true.
- SwiftPM-first: no Xcode project files. `.app` assembly only via `scripts/bundle.sh`. License GPL-3.0. No AI-attribution boilerplate anywhere.
- **The dev machine is Linux; Swift never runs locally.** Every build/test/run goes through `scripts/remote.sh` (rsyncs to and runs on `seitz@macmini1.fiber.house:~/git/sharex-mac`). `remote.sh build`/`test` do NOT re-bundle the `.app`; `remote.sh run` rebuilds+bundles+launches.
- **Local-first invariant:** the capture is written to disk (existing `AfterCapturePipeline`) before any upload attempt. A failed upload never loses the local file.
- **Fail loud:** no silent `catch {}`. Capture-path and upload-path diagnostics go through `AppLog.log` (SXApp) or thrown/propagated errors; user-visible failures surface as notifications.
- **No new external dependencies** in `Package.swift` for M2a.
- `.sxcu` compatibility is the centerpiece: real ShareX custom-uploader files must import and work unchanged for the common shape (multipart file POST + JSON/regex response parsing). Unsupported syntax must produce a clear error on import, never a silent misparse.
- Secrets (API keys, tokens) never persist in the settings JSON — they go to the Keychain, referenced by destination id.
- Reference for `.sxcu` semantics: ShareX repo at `/home/bseitz/git/sharex` (read-only) — `ShareX.UploadersLib/CustomUploader/`.

---

### Task 1: SXUpload module scaffold + core upload types

**Files:**
- Modify: `Package.swift` (add `SXUpload` target + `SXUploadTests`)
- Create: `Sources/SXUpload/SXUpload.swift` (module marker doc comment)
- Create: `Sources/SXCore/Upload/UploadResult.swift`
- Create: `Sources/SXCore/Upload/CredentialStore.swift`
- Create: `Sources/SXCore/Upload/HTTPTypes.swift`
- Create: `Tests/SXUploadTests/SmokeTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `UploadResult(url: String, thumbnailURL: String?, deletionURL: String?)` — `Equatable, Sendable`.
  - `enum UploadError: Error, Equatable` cases: `.http(status: Int, body: String)`, `.emptyURL`, `.unsupported(String)`, `.missingCredential(String)`, `.transport(String)`, `.badResponse(String)`.
  - `protocol CredentialStore: Sendable` — `func secret(for account: String) throws -> String?`, `func setSecret(_ value: String, for account: String) throws`, `func deleteSecret(for account: String) throws`.
  - `enum HTTPMethod: String, Codable, Sendable { case get = "GET", post = "POST", put = "PUT", delete = "DELETE", patch = "PATCH" }`
  - `struct PreparedRequest: Equatable, Sendable { var method: HTTPMethod; var url: String; var headers: [String: String]; var body: Data?; var contentType: String? }`
  - Tasks 3, 6, 7, 8, 9, 11 consume these.

- [ ] **Step 1: Add the targets to `Package.swift`**

In `Package.swift`, add to `targets:` (keep existing SXApp/SXCore/SXCapture/tests):
```swift
        .target(name: "SXUpload", dependencies: ["SXCore"]),
        .testTarget(name: "SXUploadTests", dependencies: ["SXUpload"]),
```
And add `"SXUpload"` to the `SXApp` executable target's `dependencies` array (so it becomes `dependencies: ["SXCore", "SXCapture", "SXUpload"]`).

- [ ] **Step 2: Create the placeholder module file**

`Sources/SXUpload/SXUpload.swift`:
```swift
// SXUpload: networking layer for share destinations — URLSession execution and
// the custom-uploader / Imgur provider clients. Pure logic (models, parsing,
// settings) lives in SXCore; this target is the impure networking edge.
```

- [ ] **Step 3: Create the core upload types in SXCore**

`Sources/SXCore/Upload/UploadResult.swift`:
```swift
import Foundation

public struct UploadResult: Equatable, Sendable {
    public var url: String
    public var thumbnailURL: String?
    public var deletionURL: String?
    public init(url: String, thumbnailURL: String? = nil, deletionURL: String? = nil) {
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.deletionURL = deletionURL
    }
}

public enum UploadError: Error, Equatable, Sendable {
    case http(status: Int, body: String)
    case emptyURL
    case unsupported(String)
    case missingCredential(String)
    case transport(String)
    case badResponse(String)
}
```

`Sources/SXCore/Upload/CredentialStore.swift`:
```swift
import Foundation

/// Abstracts secret storage so uploaders can be tested without the Keychain.
/// `account` is the storage key (e.g. "<destinationID>/token").
public protocol CredentialStore: Sendable {
    func secret(for account: String) throws -> String?
    func setSecret(_ value: String, for account: String) throws
    func deleteSecret(for account: String) throws
}
```

`Sources/SXCore/Upload/HTTPTypes.swift`:
```swift
import Foundation

public enum HTTPMethod: String, Codable, Sendable {
    case get = "GET", post = "POST", put = "PUT", delete = "DELETE", patch = "PATCH"
}

/// A fully-resolved HTTP request ready to hand to an HTTPClient.
public struct PreparedRequest: Equatable, Sendable {
    public var method: HTTPMethod
    public var url: String
    public var headers: [String: String]
    public var body: Data?
    public var contentType: String?
    public init(method: HTTPMethod, url: String, headers: [String: String] = [:],
                body: Data? = nil, contentType: String? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.contentType = contentType
    }
}
```

`Tests/SXUploadTests/SmokeTests.swift`:
```swift
import Testing
@testable import SXUpload

@Test func sxUploadModuleCompiles() {
    #expect(true)
}
```

- [ ] **Step 4: Build and test**

Run: `scripts/remote.sh test`
Expected: build succeeds; all existing tests plus the new smoke test pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Add SXUpload module scaffold and core upload types"
```

---

### Task 2: Request body encoding (multipart / form / json / binary)

**Files:**
- Create: `Sources/SXCore/Upload/RequestBodyEncoder.swift`
- Create: `Tests/SXCoreTests/RequestBodyEncoderTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct FilePart: Equatable, Sendable { var fieldName: String; var filename: String; var mimeType: String; var data: Data }`
  - `enum RequestBodySpec: Equatable, Sendable { case none; case multipart(fields: [(String, String)], file: FilePart?); case formURLEncoded([(String, String)]); case json(Data); case binary(FilePart) }`
  - `enum RequestBodyEncoder { static func encode(_ spec: RequestBodySpec, boundary: String) -> (body: Data?, contentType: String?) }`
  - Note `[(String, String)]` (ordered pairs), not a dictionary, so field order is stable and testable.
  - Task 6 (custom uploader) consumes these.

- [ ] **Step 1: Write failing tests `Tests/SXCoreTests/RequestBodyEncoderTests.swift`**

```swift
import Foundation
import Testing
@testable import SXCore

@Suite struct RequestBodyEncoderTests {
    private func str(_ data: Data?) -> String { String(data: data ?? Data(), encoding: .utf8) ?? "" }

    @Test func multipartEncodesFieldsAndFileWithBoundary() {
        let file = FilePart(fieldName: "file", filename: "a.png", mimeType: "image/png",
                            data: Data([0xDE, 0xAD]))
        let (body, ct) = RequestBodyEncoder.encode(
            .multipart(fields: [("k", "v")], file: file), boundary: "BND")
        #expect(ct == "multipart/form-data; boundary=BND")
        let s = str(body)
        #expect(s.contains("--BND\r\nContent-Disposition: form-data; name=\"k\"\r\n\r\nv\r\n"))
        #expect(s.contains(
            "--BND\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.png\"\r\n"
            + "Content-Type: image/png\r\n\r\n"))
        #expect(s.hasSuffix("--BND--\r\n"))
    }

    @Test func formURLEncodedEscapesReservedCharacters() {
        let (body, ct) = RequestBodyEncoder.encode(
            .formURLEncoded([("a b", "c&d"), ("x", "y")]), boundary: "BND")
        #expect(ct == "application/x-www-form-urlencoded")
        #expect(str(body) == "a%20b=c%26d&x=y")
    }

    @Test func jsonPassesThroughWithContentType() {
        let payload = Data(#"{"z":1}"#.utf8)
        let (body, ct) = RequestBodyEncoder.encode(.json(payload), boundary: "BND")
        #expect(ct == "application/json")
        #expect(body == payload)
    }

    @Test func binarySetsFileMimeAndRawBytes() {
        let file = FilePart(fieldName: "", filename: "a.png", mimeType: "image/png",
                            data: Data([1, 2, 3]))
        let (body, ct) = RequestBodyEncoder.encode(.binary(file), boundary: "BND")
        #expect(ct == "image/png")
        #expect(body == Data([1, 2, 3]))
    }

    @Test func noneYieldsNilBody() {
        let (body, ct) = RequestBodyEncoder.encode(.none, boundary: "BND")
        #expect(body == nil)
        #expect(ct == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: compile FAILURE — `cannot find 'RequestBodyEncoder' in scope`.

- [ ] **Step 3: Write `Sources/SXCore/Upload/RequestBodyEncoder.swift`**

```swift
import Foundation

public struct FilePart: Equatable, Sendable {
    public var fieldName: String
    public var filename: String
    public var mimeType: String
    public var data: Data
    public init(fieldName: String, filename: String, mimeType: String, data: Data) {
        self.fieldName = fieldName
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
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
    public static func encode(_ spec: RequestBodySpec,
                              boundary: String) -> (body: Data?, contentType: String?) {
        switch spec {
        case .none:
            return (nil, nil)

        case let .multipart(fields, file):
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
                data.append(file.data)
                append("\r\n")
            }
            append("--\(boundary)--\r\n")
            return (data, "multipart/form-data; boundary=\(boundary)")

        case let .formURLEncoded(pairs):
            let encoded = pairs.map { "\(formEscape($0.0))=\(formEscape($0.1))" }.joined(separator: "&")
            return (Data(encoded.utf8), "application/x-www-form-urlencoded")

        case let .json(payload):
            return (payload, "application/json")

        case let .binary(file):
            return (file.data, file.mimeType)
        }
    }

    /// Percent-encode for application/x-www-form-urlencoded (space → %20, not '+').
    private static func formEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: all RequestBodyEncoder tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Add HTTP request body encoder (multipart/form/json/binary)"
```

---

### Task 3: HTTPClient protocol + URLSession implementation + mock

**Files:**
- Create: `Sources/SXUpload/HTTPClient.swift`
- Create: `Sources/SXUpload/URLSessionHTTPClient.swift`
- Create: `Tests/SXUploadTests/URLSessionHTTPClientTests.swift`

**Interfaces:**
- Consumes: `PreparedRequest`, `UploadError` (Task 1).
- Produces:
  - `struct HTTPResponse: Equatable, Sendable { var status: Int; var headers: [String: String]; var body: Data }`
  - `protocol HTTPClient: Sendable { func send(_ request: PreparedRequest) async throws -> HTTPResponse }`
  - `struct URLSessionHTTPClient: HTTPClient` with `init(session: URLSession = .shared)`.
  - Tasks 7, 8 consume `HTTPClient`/`HTTPResponse`.

- [ ] **Step 1: Write failing tests `Tests/SXUploadTests/URLSessionHTTPClientTests.swift`**

Uses a custom `URLProtocol` to intercept requests — no real network.
```swift
import Foundation
import Testing
@testable import SXUpload
@testable import SXCore

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubbedClient() -> URLSessionHTTPClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSessionHTTPClient(session: URLSession(configuration: config))
}

@Suite struct URLSessionHTTPClientTests {
    @Test func sendsBodyAndReturnsStatusHeadersBody() async throws {
        StubURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            let resp = HTTPURLResponse(url: request.url!, statusCode: 201,
                                       httpVersion: nil,
                                       headerFields: ["X-Test": "yes"])!
            return (resp, Data(#"{"ok":true}"#.utf8))
        }
        let req = PreparedRequest(method: .post, url: "https://example.com/up",
                                  headers: ["Authorization": "Bearer k"],
                                  body: Data("hi".utf8), contentType: "text/plain")
        let resp = try await stubbedClient().send(req)
        #expect(resp.status == 201)
        #expect(resp.headers["X-Test"] == "yes")
        #expect(String(data: resp.body, encoding: .utf8) == #"{"ok":true}"#)
    }

    @Test func invalidURLThrowsTransport() async {
        let req = PreparedRequest(method: .get, url: "http://a b c")   // space = invalid
        await #expect(throws: UploadError.self) {
            _ = try await stubbedClient().send(req)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: compile FAILURE — `cannot find 'URLSessionHTTPClient' in scope`.

- [ ] **Step 3: Write `Sources/SXUpload/HTTPClient.swift`**

```swift
import Foundation
import SXCore

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: PreparedRequest) async throws -> HTTPResponse
}
```

- [ ] **Step 4: Write `Sources/SXUpload/URLSessionHTTPClient.swift`**

```swift
import Foundation
import SXCore

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: PreparedRequest) async throws -> HTTPResponse {
        guard let url = URL(string: request.url) else {
            throw UploadError.transport("Invalid URL: \(request.url)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if let contentType = request.contentType {
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        urlRequest.httpBody = request.body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: URLSessionHTTPClient tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "Add HTTPClient protocol with URLSession implementation"
```

---

### Task 4: `.sxcu` custom-uploader model + parser

**Files:**
- Create: `Sources/SXCore/Upload/CustomUploaderConfig.swift`
- Create: `Tests/SXCoreTests/CustomUploaderConfigTests.swift`
- Create: `Tests/SXCoreTests/Fixtures/imgur.sxcu`
- Create: `Tests/SXCoreTests/Fixtures/generic-multipart.sxcu`

**Interfaces:**
- Consumes: `HTTPMethod`, `UploadError` (Task 1).
- Produces:
  - `struct CustomUploaderConfig: Codable, Equatable, Sendable` with fields (all optional except as noted): `version: String?`, `name: String?`, `requestMethod: HTTPMethod` (default `.post`), `requestURL: String`, `parameters: [String: String]`, `headers: [String: String]`, `body: CustomUploaderBody` (default `.multipartFormData`), `arguments: [String: String]`, `fileFormName: String?`, `data: String?` (raw body template for JSON/binary bodies), `regexList: [String]`, `url: String?`, `thumbnailURL: String?`, `deletionURL: String?`, `errorMessage: String?`.
  - `enum CustomUploaderBody: String, Codable, Sendable { case none = "None", multipartFormData = "MultipartFormData", formURLEncoded = "FormURLEncoded", json = "JSON", binary = "Binary" }`
  - `static CustomUploaderConfig.parse(_ data: Data) throws -> CustomUploaderConfig` — maps ShareX's PascalCase JSON keys; throws `UploadError.badResponse` on malformed JSON and `UploadError.unsupported` for a body type it can't handle (`XML`).
  - Tasks 6, 12 consume this.

- [ ] **Step 1: Create fixtures**

`Tests/SXCoreTests/Fixtures/imgur.sxcu`:
```json
{
  "Version": "15.0.0",
  "Name": "Imgur (anonymous)",
  "DestinationType": "ImageUploader",
  "RequestMethod": "POST",
  "RequestURL": "https://api.imgur.com/3/image",
  "Headers": { "Authorization": "Client-ID abc123" },
  "Body": "MultipartFormData",
  "FileFormName": "image",
  "URL": "{json:data.link}",
  "DeletionURL": "https://imgur.com/delete/{json:data.deletehash}"
}
```

`Tests/SXCoreTests/Fixtures/generic-multipart.sxcu`:
```json
{
  "Version": "14.0.0",
  "Name": "My Server",
  "RequestMethod": "POST",
  "RequestURL": "https://up.example.com/api",
  "Headers": { "X-Auth-Token": "SECRET" },
  "Body": "MultipartFormData",
  "Arguments": { "album": "screenshots" },
  "FileFormName": "file",
  "RegexList": ["https://cdn\\.example\\.com/(\\w+)"],
  "URL": "{regex:1}",
  "ThumbnailURL": "{regex:1|1}.thumb"
}
```

Add fixtures to the test target's resources: in `Package.swift`, change the `SXCoreTests` test target to include resources:
```swift
        .testTarget(name: "SXCoreTests", dependencies: ["SXCore"],
                    resources: [.copy("Fixtures")]),
```

- [ ] **Step 2: Write failing tests `Tests/SXCoreTests/CustomUploaderConfigTests.swift`**

```swift
import Foundation
import Testing
@testable import SXCore

private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "sxcu",
                               subdirectory: "Fixtures")!
    return try Data(contentsOf: url)
}

@Suite struct CustomUploaderConfigTests {
    @Test func parsesImgurFixture() throws {
        let c = try CustomUploaderConfig.parse(fixture("imgur"))
        #expect(c.name == "Imgur (anonymous)")
        #expect(c.requestMethod == .post)
        #expect(c.requestURL == "https://api.imgur.com/3/image")
        #expect(c.headers["Authorization"] == "Client-ID abc123")
        #expect(c.body == .multipartFormData)
        #expect(c.fileFormName == "image")
        #expect(c.url == "{json:data.link}")
        #expect(c.deletionURL == "https://imgur.com/delete/{json:data.deletehash}")
    }

    @Test func parsesGenericFixtureWithArgumentsAndRegex() throws {
        let c = try CustomUploaderConfig.parse(fixture("generic-multipart"))
        #expect(c.arguments["album"] == "screenshots")
        #expect(c.fileFormName == "file")
        #expect(c.regexList == ["https://cdn\\.example\\.com/(\\w+)"])
        #expect(c.url == "{regex:1}")
        #expect(c.thumbnailURL == "{regex:1|1}.thumb")
    }

    @Test func defaultsMethodPostAndBodyMultipart() throws {
        let c = try CustomUploaderConfig.parse(Data(#"{"RequestURL":"https://x"}"#.utf8))
        #expect(c.requestMethod == .post)
        #expect(c.body == .multipartFormData)
    }

    @Test func malformedJSONThrows() {
        #expect(throws: UploadError.self) {
            _ = try CustomUploaderConfig.parse(Data("not json".utf8))
        }
    }

    @Test func xmlBodyIsUnsupported() {
        let json = Data(#"{"RequestURL":"https://x","Body":"XML"}"#.utf8)
        #expect(throws: UploadError.self) {
            _ = try CustomUploaderConfig.parse(json)
        }
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: compile FAILURE — `cannot find 'CustomUploaderConfig' in scope`.

- [ ] **Step 4: Write `Sources/SXCore/Upload/CustomUploaderConfig.swift`**

```swift
import Foundation

public enum CustomUploaderBody: String, Codable, Sendable {
    case none = "None"
    case multipartFormData = "MultipartFormData"
    case formURLEncoded = "FormURLEncoded"
    case json = "JSON"
    case binary = "Binary"
}

public struct CustomUploaderConfig: Codable, Equatable, Sendable {
    public var version: String?
    public var name: String?
    public var requestMethod: HTTPMethod
    public var requestURL: String
    public var parameters: [String: String]
    public var headers: [String: String]
    public var body: CustomUploaderBody
    public var arguments: [String: String]
    public var fileFormName: String?
    public var data: String?
    public var regexList: [String]
    public var url: String?
    public var thumbnailURL: String?
    public var deletionURL: String?
    public var errorMessage: String?

    public init(requestURL: String,
                requestMethod: HTTPMethod = .post,
                name: String? = nil,
                headers: [String: String] = [:],
                parameters: [String: String] = [:],
                body: CustomUploaderBody = .multipartFormData,
                arguments: [String: String] = [:],
                fileFormName: String? = nil,
                data: String? = nil,
                regexList: [String] = [],
                url: String? = nil,
                thumbnailURL: String? = nil,
                deletionURL: String? = nil,
                errorMessage: String? = nil,
                version: String? = nil) {
        self.requestURL = requestURL
        self.requestMethod = requestMethod
        self.name = name
        self.headers = headers
        self.parameters = parameters
        self.body = body
        self.arguments = arguments
        self.fileFormName = fileFormName
        self.data = data
        self.regexList = regexList
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.deletionURL = deletionURL
        self.errorMessage = errorMessage
        self.version = version
    }

    // ShareX .sxcu keys are PascalCase.
    private enum CodingKeys: String, CodingKey {
        case version = "Version"
        case name = "Name"
        case requestMethod = "RequestMethod"
        case requestURL = "RequestURL"
        case parameters = "Parameters"
        case headers = "Headers"
        case body = "Body"
        case arguments = "Arguments"
        case fileFormName = "FileFormName"
        case data = "Data"
        case regexList = "RegexList"
        case url = "URL"
        case thumbnailURL = "ThumbnailURL"
        case deletionURL = "DeletionURL"
        case errorMessage = "ErrorMessage"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestURL = try c.decodeIfPresent(String.self, forKey: .requestURL) ?? ""
        requestMethod = try c.decodeIfPresent(HTTPMethod.self, forKey: .requestMethod) ?? .post
        name = try c.decodeIfPresent(String.self, forKey: .name)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        parameters = try c.decodeIfPresent([String: String].self, forKey: .parameters) ?? [:]
        body = try c.decodeIfPresent(CustomUploaderBody.self, forKey: .body) ?? .multipartFormData
        arguments = try c.decodeIfPresent([String: String].self, forKey: .arguments) ?? [:]
        fileFormName = try c.decodeIfPresent(String.self, forKey: .fileFormName)
        data = try c.decodeIfPresent(String.self, forKey: .data)
        regexList = try c.decodeIfPresent([String].self, forKey: .regexList) ?? []
        url = try c.decodeIfPresent(String.self, forKey: .url)
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL)
        deletionURL = try c.decodeIfPresent(String.self, forKey: .deletionURL)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    /// Parse a .sxcu file. Throws `UploadError.badResponse` on malformed JSON,
    /// `UploadError.unsupported` for body types M2a can't execute (e.g. XML).
    public static func parse(_ data: Data) throws -> CustomUploaderConfig {
        // Reject an unsupported body BEFORE decoding maps it to a case: the raw
        // "Body" string may be a value the enum doesn't model (e.g. "XML").
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let bodyString = object["Body"] as? String,
           CustomUploaderBody(rawValue: bodyString) == nil {
            throw UploadError.unsupported("Unsupported request body type: \(bodyString)")
        }
        do {
            return try JSONDecoder().decode(CustomUploaderConfig.self, from: data)
        } catch {
            throw UploadError.badResponse("Invalid .sxcu JSON: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: all CustomUploaderConfig tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "Add .sxcu custom-uploader config model and parser"
```

---

### Task 5: Response-URL syntax parser (`{json:}` / `{regex:}` / `{response}` / `{header:}`)

**Files:**
- Create: `Sources/SXCore/Upload/ResponseURLParser.swift`
- Create: `Tests/SXCoreTests/ResponseURLParserTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct ResponseContext: Sendable { var body: String; var headers: [String: String]; var regexList: [String] }`
  - `enum ResponseURLParser { static func resolve(_ template: String, context: ResponseContext) -> String }`
  - Supported tokens: `{response}`, `{json:dotted.path}` (with `[n]` array indices), `{regex:N}` (whole match of regexList[N-1]), `{regex:N|G}` (group G), `{header:Name}`. Unknown tokens resolve to empty string. Literal text passes through.
  - Task 6 consumes this.

- [ ] **Step 1: Write failing tests `Tests/SXCoreTests/ResponseURLParserTests.swift`**

```swift
import Foundation
import Testing
@testable import SXCore

private func ctx(body: String = "", headers: [String: String] = [:],
                 regex: [String] = []) -> ResponseContext {
    ResponseContext(body: body, headers: headers, regexList: regex)
}

@Suite struct ResponseURLParserTests {
    @Test func responseTokenReturnsWholeBody() {
        let out = ResponseURLParser.resolve("{response}", context: ctx(body: "hello"))
        #expect(out == "hello")
    }

    @Test func jsonDottedPath() {
        let body = #"{"data":{"link":"https://i/x.png"}}"#
        let out = ResponseURLParser.resolve("{json:data.link}", context: ctx(body: body))
        #expect(out == "https://i/x.png")
    }

    @Test func jsonArrayIndex() {
        let body = #"{"files":[{"url":"a"},{"url":"b"}]}"#
        let out = ResponseURLParser.resolve("{json:files[1].url}", context: ctx(body: body))
        #expect(out == "b")
    }

    @Test func regexWholeMatchAndGroup() {
        let body = "id=https://cdn/abc123 end"
        let c = ctx(body: body, regex: ["https://cdn/(\\w+)"])
        #expect(ResponseURLParser.resolve("{regex:1}", context: c) == "https://cdn/abc123")
        #expect(ResponseURLParser.resolve("{regex:1|1}", context: c) == "abc123")
    }

    @Test func headerLookupIsCaseInsensitive() {
        let c = ctx(headers: ["Location": "https://x/y"])
        #expect(ResponseURLParser.resolve("{header:location}", context: c) == "https://x/y")
    }

    @Test func literalTextAndSurroundingChars() {
        let body = #"{"hash":"h1"}"#
        let out = ResponseURLParser.resolve("https://site/{json:hash}/view", context: ctx(body: body))
        #expect(out == "https://site/h1/view")
    }

    @Test func unknownOrMissingTokenResolvesEmpty() {
        #expect(ResponseURLParser.resolve("{json:nope}", context: ctx(body: "{}")) == "")
        #expect(ResponseURLParser.resolve("a{bogus}b", context: ctx()) == "ab")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: compile FAILURE — `cannot find 'ResponseURLParser' in scope`.

- [ ] **Step 3: Write `Sources/SXCore/Upload/ResponseURLParser.swift`**

```swift
import Foundation

public struct ResponseContext: Sendable {
    public var body: String
    public var headers: [String: String]
    public var regexList: [String]
    public init(body: String, headers: [String: String], regexList: [String]) {
        self.body = body
        self.headers = headers
        self.regexList = regexList
    }
}

public enum ResponseURLParser {
    public static func resolve(_ template: String, context: ResponseContext) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[rest.startIndex..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                out += rest[open...]          // unmatched '{' — emit literally
                return out
            }
            let token = String(rest[rest.index(after: open)..<close])
            out += value(for: token, context: context)
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return out
    }

    private static func value(for token: String, context: ResponseContext) -> String {
        if token == "response" { return context.body }
        if let arg = suffix(token, after: "json:") { return jsonValue(path: arg, body: context.body) }
        if let arg = suffix(token, after: "regex:") { return regexValue(spec: arg, context: context) }
        if let arg = suffix(token, after: "header:") {
            let lower = arg.lowercased()
            return context.headers.first { $0.key.lowercased() == lower }?.value ?? ""
        }
        return ""   // unknown token
    }

    private static func suffix(_ token: String, after prefix: String) -> String? {
        token.hasPrefix(prefix) ? String(token.dropFirst(prefix.count)) : nil
    }

    /// Dotted path with optional `[n]` array indices, e.g. `data.files[0].url`.
    private static func jsonValue(path: String, body: String) -> String {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return "" }
        var current: Any? = root
        for component in path.split(separator: ".") {
            var key = Substring(component)
            var indices: [Int] = []
            while let open = key.lastIndex(of: "["), key.hasSuffix("]") {
                let idxStr = key[key.index(after: open)..<key.index(before: key.endIndex)]
                if let i = Int(idxStr) { indices.insert(i, at: 0) }
                key = key[key.startIndex..<open]
            }
            if !key.isEmpty {
                current = (current as? [String: Any])?[String(key)]
            }
            for i in indices {
                guard let array = current as? [Any], i >= 0, i < array.count else { return "" }
                current = array[i]
            }
        }
        switch current {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }

    /// `N` (whole match of regexList[N-1]) or `N|G` (capture group G).
    private static func regexValue(spec: String, context: ResponseContext) -> String {
        let parts = spec.split(separator: "|")
        guard let index = Int(parts.first ?? ""), index >= 1,
              index <= context.regexList.count,
              let regex = try? NSRegularExpression(pattern: context.regexList[index - 1]) else {
            return ""
        }
        let group = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        let range = NSRange(context.body.startIndex..., in: context.body)
        guard let match = regex.firstMatch(in: context.body, range: range),
              group < match.numberOfRanges,
              let r = Range(match.range(at: group), in: context.body) else { return "" }
        return String(context.body[r])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: all ResponseURLParser tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Add ShareX response-URL syntax parser"
```

---

### Task 6: Custom-uploader engine (pure request build + response parse)

**Files:**
- Create: `Sources/SXCore/Upload/CustomUploaderEngine.swift`
- Create: `Tests/SXCoreTests/CustomUploaderEngineTests.swift`

**Interfaces:**
- Consumes: `CustomUploaderConfig`, `CustomUploaderBody` (Task 4), `RequestBodySpec`/`FilePart`/`RequestBodyEncoder` (Task 2), `ResponseURLParser`/`ResponseContext` (Task 5), `PreparedRequest`/`HTTPMethod` (Task 1), `UploadError` (Task 1).
- Produces:
  - `enum CustomUploaderEngine`:
    - `static func prepare(config: CustomUploaderConfig, file: FilePart, boundary: String) throws -> PreparedRequest`
    - `static func parseResult(config: CustomUploaderConfig, status: Int, body: Data, headers: [String: String]) throws -> UploadResult`
  - `prepare` builds the multipart/form/json/binary body per `config.body`, appends `arguments` as fields/params, applies `headers`, and appends `parameters` as URL query. `parseResult` runs the `url`/`thumbnailURL`/`deletionURL` templates via `ResponseURLParser`, throws `UploadError.http` on non-2xx, `UploadError.emptyURL` if the resolved url is empty.
  - Task 7 consumes this.

- [ ] **Step 1: Write failing tests `Tests/SXCoreTests/CustomUploaderEngineTests.swift`**

```swift
import Foundation
import Testing
@testable import SXCore

private let png = FilePart(fieldName: "IGNORED", filename: "shot.png",
                           mimeType: "image/png", data: Data([0xAB]))

@Suite struct CustomUploaderEngineTests {
    @Test func prepareBuildsMultipartWithFileFormNameAndArguments() throws {
        var config = CustomUploaderConfig(requestURL: "https://up/api")
        config.body = .multipartFormData
        config.fileFormName = "file"
        config.arguments = ["album": "shots"]
        config.headers = ["X-Auth": "k"]
        let req = try CustomUploaderEngine.prepare(config: config, file: png, boundary: "BND")
        #expect(req.method == .post)
        #expect(req.url == "https://up/api")
        #expect(req.headers["X-Auth"] == "k")
        let s = String(data: req.body ?? Data(), encoding: .utf8) ?? ""
        #expect(s.contains("name=\"album\"\r\n\r\nshots\r\n"))
        #expect(s.contains("name=\"file\"; filename=\"shot.png\""))
        #expect(req.contentType == "multipart/form-data; boundary=BND")
    }

    @Test func prepareAppendsParametersAsQuery() throws {
        var config = CustomUploaderConfig(requestURL: "https://up/api")
        config.parameters = ["key": "v1"]
        let req = try CustomUploaderEngine.prepare(config: config, file: png, boundary: "BND")
        #expect(req.url == "https://up/api?key=v1")
    }

    @Test func prepareBinaryBodyUsesRawFileBytes() throws {
        var config = CustomUploaderConfig(requestURL: "https://up/bin")
        config.body = .binary
        let req = try CustomUploaderEngine.prepare(config: config, file: png, boundary: "BND")
        #expect(req.body == png.data)
        #expect(req.contentType == "image/png")
    }

    @Test func parseResultResolvesURLFromJSON() throws {
        var config = CustomUploaderConfig(requestURL: "https://up")
        config.url = "{json:data.link}"
        config.deletionURL = "https://d/{json:data.hash}"
        let body = Data(#"{"data":{"link":"https://i/x.png","hash":"h9"}}"#.utf8)
        let result = try CustomUploaderEngine.parseResult(
            config: config, status: 200, body: body, headers: [:])
        #expect(result.url == "https://i/x.png")
        #expect(result.deletionURL == "https://d/h9")
    }

    @Test func parseResultThrowsOnHTTPError() {
        var config = CustomUploaderConfig(requestURL: "https://up")
        config.url = "{response}"
        #expect(throws: UploadError.self) {
            _ = try CustomUploaderEngine.parseResult(
                config: config, status: 500, body: Data("boom".utf8), headers: [:])
        }
    }

    @Test func parseResultThrowsWhenResolvedURLEmpty() {
        var config = CustomUploaderConfig(requestURL: "https://up")
        config.url = "{json:missing}"
        #expect(throws: UploadError.self) {
            _ = try CustomUploaderEngine.parseResult(
                config: config, status: 200, body: Data("{}".utf8), headers: [:])
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: compile FAILURE — `cannot find 'CustomUploaderEngine' in scope`.

- [ ] **Step 3: Write `Sources/SXCore/Upload/CustomUploaderEngine.swift`**

```swift
import Foundation

public enum CustomUploaderEngine {
    public static func prepare(config: CustomUploaderConfig, file: FilePart,
                               boundary: String) throws -> PreparedRequest {
        let filePart = FilePart(fieldName: config.fileFormName ?? "file",
                                filename: file.filename, mimeType: file.mimeType, data: file.data)
        let argFields = config.arguments.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }

        let spec: RequestBodySpec
        switch config.body {
        case .none:
            spec = .none
        case .multipartFormData:
            spec = .multipart(fields: argFields, file: config.fileFormName != nil ? filePart : nil)
        case .formURLEncoded:
            spec = .formURLEncoded(argFields)
        case .json:
            spec = .json(Data((config.data ?? "").utf8))
        case .binary:
            spec = .binary(filePart)
        }
        let (body, contentType) = RequestBodyEncoder.encode(spec, boundary: boundary)

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
        guard let url = resolve(config.url) else { throw UploadError.emptyURL }
        return UploadResult(url: url,
                            thumbnailURL: resolve(config.thumbnailURL),
                            deletionURL: resolve(config.deletionURL))
    }

    private static func escape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: all CustomUploaderEngine tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Add custom-uploader engine (request build + response parse)"
```

---

### Task 7: Uploader protocol + CustomUploaderClient + ImgurUploader

**Files:**
- Create: `Sources/SXUpload/Uploader.swift`
- Create: `Sources/SXUpload/CustomUploaderClient.swift`
- Create: `Sources/SXUpload/ImgurUploader.swift`
- Create: `Tests/SXUploadTests/CustomUploaderClientTests.swift`
- Create: `Tests/SXUploadTests/ImgurUploaderTests.swift`

**Interfaces:**
- Consumes: `HTTPClient`/`HTTPResponse` (Task 3), `CustomUploaderConfig`/`CustomUploaderEngine` (Tasks 4/6), `FilePart` (Task 2), `UploadResult`/`UploadError` (Task 1).
- Produces:
  - `protocol Uploader: Sendable { func upload(_ file: FilePart) async throws -> UploadResult }`
  - `struct CustomUploaderClient: Uploader` — `init(config: CustomUploaderConfig, http: HTTPClient, boundaryProvider: @Sendable () -> String = { "SXBoundary-" + UUID().uuidString })`.
  - `struct ImgurUploader: Uploader` — `init(clientID: String, http: HTTPClient)`; anonymous upload to `https://api.imgur.com/3/image`, field `image`, header `Authorization: Client-ID <id>`, parses `{json:data.link}` + deletehash.
  - Tasks 12 consumes both.

- [ ] **Step 1: Write failing tests**

`Tests/SXUploadTests/CustomUploaderClientTests.swift`:
```swift
import Foundation
import Testing
@testable import SXUpload
@testable import SXCore

struct FakeHTTP: HTTPClient {
    let response: HTTPResponse
    let capture: @Sendable (PreparedRequest) -> Void
    func send(_ request: PreparedRequest) async throws -> HTTPResponse {
        capture(request); return response
    }
}

private let png = FilePart(fieldName: "file", filename: "s.png",
                           mimeType: "image/png", data: Data([1, 2]))

@Suite struct CustomUploaderClientTests {
    @Test func uploadsAndParsesURL() async throws {
        var config = CustomUploaderConfig(requestURL: "https://up/api")
        config.fileFormName = "file"
        config.url = "{json:link}"
        let http = FakeHTTP(
            response: HTTPResponse(status: 200, headers: [:],
                                   body: Data(#"{"link":"https://i/x"}"#.utf8)),
            capture: { req in
                #expect(req.url == "https://up/api")
                #expect(req.method == .post)
            })
        let client = CustomUploaderClient(config: config, http: http,
                                          boundaryProvider: { "BND" })
        let result = try await client.upload(png)
        #expect(result.url == "https://i/x")
    }

    @Test func httpErrorPropagates() async {
        var config = CustomUploaderConfig(requestURL: "https://up")
        config.url = "{response}"
        let http = FakeHTTP(response: HTTPResponse(status: 403, headers: [:],
                                                   body: Data("nope".utf8)),
                            capture: { _ in })
        let client = CustomUploaderClient(config: config, http: http, boundaryProvider: { "BND" })
        await #expect(throws: UploadError.self) { _ = try await client.upload(png) }
    }
}
```

`Tests/SXUploadTests/ImgurUploaderTests.swift`:
```swift
import Foundation
import Testing
@testable import SXUpload
@testable import SXCore

@Suite struct ImgurUploaderTests {
    @Test func anonymousUploadParsesLink() async throws {
        let http = FakeHTTP(
            response: HTTPResponse(status: 200, headers: [:],
                body: Data(#"{"data":{"link":"https://i.imgur.com/a.png","deletehash":"dh"}}"#.utf8)),
            capture: { req in
                #expect(req.url == "https://api.imgur.com/3/image")
                #expect(req.headers["Authorization"] == "Client-ID CID")
            })
        let up = ImgurUploader(clientID: "CID", http: http)
        let file = FilePart(fieldName: "image", filename: "a.png",
                            mimeType: "image/png", data: Data([9]))
        let result = try await up.upload(file)
        #expect(result.url == "https://i.imgur.com/a.png")
        #expect(result.deletionURL == "https://imgur.com/delete/dh")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: compile FAILURE — `cannot find 'CustomUploaderClient' in scope`.

- [ ] **Step 3: Write the implementations**

`Sources/SXUpload/Uploader.swift`:
```swift
import Foundation
import SXCore

public protocol Uploader: Sendable {
    func upload(_ file: FilePart) async throws -> UploadResult
}
```

`Sources/SXUpload/CustomUploaderClient.swift`:
```swift
import Foundation
import SXCore

public struct CustomUploaderClient: Uploader {
    private let config: CustomUploaderConfig
    private let http: HTTPClient
    private let boundaryProvider: @Sendable () -> String

    public init(config: CustomUploaderConfig, http: HTTPClient,
                boundaryProvider: @escaping @Sendable () -> String = {
                    "SXBoundary-" + UUID().uuidString
                }) {
        self.config = config
        self.http = http
        self.boundaryProvider = boundaryProvider
    }

    public func upload(_ file: FilePart) async throws -> UploadResult {
        let request = try CustomUploaderEngine.prepare(config: config, file: file,
                                                       boundary: boundaryProvider())
        let response = try await http.send(request)
        return try CustomUploaderEngine.parseResult(config: config, status: response.status,
                                                    body: response.body, headers: response.headers)
    }
}
```

`Sources/SXUpload/ImgurUploader.swift`:
```swift
import Foundation
import SXCore

/// Anonymous Imgur upload. OAuth (authenticated albums) is deferred.
public struct ImgurUploader: Uploader {
    private let clientID: String
    private let http: HTTPClient

    public init(clientID: String, http: HTTPClient) {
        self.clientID = clientID
        self.http = http
    }

    public func upload(_ file: FilePart) async throws -> UploadResult {
        var config = CustomUploaderConfig(requestURL: "https://api.imgur.com/3/image")
        config.headers = ["Authorization": "Client-ID \(clientID)"]
        config.body = .multipartFormData
        config.fileFormName = "image"
        config.url = "{json:data.link}"
        config.deletionURL = "https://imgur.com/delete/{json:data.deletehash}"
        return try await CustomUploaderClient(config: config, http: http).upload(file)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: all CustomUploaderClient + Imgur tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Add Uploader protocol, custom-uploader client, and Imgur uploader"
```

---

### Task 8: Upload settings + destinations + AppSettings schema v2 migration

**Files:**
- Create: `Sources/SXCore/Upload/UploadSettings.swift`
- Modify: `Sources/SXCore/AppSettings.swift`
- Modify: `Sources/SXCore/SettingsStore.swift`
- Create: `Tests/SXCoreTests/UploadSettingsMigrationTests.swift`

**Interfaces:**
- Consumes: `CustomUploaderConfig` (Task 4), `AppSettings`/`SettingsStore` (existing).
- Produces:
  - `enum UploadDestinationKind: String, Codable, Sendable { case customUploader, imgur }`
  - `struct UploadDestination: Codable, Equatable, Sendable, Identifiable { var id: String; var name: String; var kind: UploadDestinationKind; var customUploader: CustomUploaderConfig?; var imgurClientID: String? }`  *(secret client IDs/tokens are stripped to the Keychain on import; see Task 12 — the plaintext fields here hold only non-secret config)*
  - `struct UploadSettings: Codable, Equatable, Sendable { var uploadAfterCapture: Bool; var activeDestinationID: String?; var destinations: [UploadDestination] }` with `static let disabled` (empty).
  - `AppSettings` gains `var upload: UploadSettings` and `schemaVersion` default becomes `2`.
  - `SettingsStore.loadOrDefault()` migrates a v1 JSON (no `upload` key, `schemaVersion` 1 or absent) by injecting `UploadSettings.disabled` and bumping to 2, without data loss and without emitting a `SettingsLoadIssue`.
  - Tasks 12, 13 consume these.

- [ ] **Step 1: Write failing tests `Tests/SXCoreTests/UploadSettingsMigrationTests.swift`**

```swift
import Foundation
import Testing
@testable import SXCore

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json")
}

@Suite struct UploadSettingsMigrationTests {
    @Test func defaultsIncludeDisabledUploadAtSchema2() {
        #expect(AppSettings.default.schemaVersion == 2)
        #expect(AppSettings.default.upload == UploadSettings.disabled)
        #expect(AppSettings.default.upload.uploadAfterCapture == false)
    }

    @Test func migratesV1FileWithoutUploadKey() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // A settings.json written by M1 (schemaVersion 1, no `upload`).
        let v1 = """
        {"schemaVersion":1,"captureSavePath":"~/Pictures/ShareX",
         "filenameTemplate":"Screenshot_%y","saveToDisk":true,"copyToClipboard":true,
         "showNotification":true,
         "hotkeys":{"fullscreen":{"keyCode":20,"modifiers":2560},
                    "region":{"keyCode":21,"modifiers":2560},
                    "window":{"keyCode":23,"modifiers":2560}}}
        """
        try Data(v1.utf8).write(to: url)
        let (settings, issue) = SettingsStore(fileURL: url).loadOrDefault()
        #expect(issue == nil)                              // migration is not an error
        #expect(settings.schemaVersion == 2)
        #expect(settings.captureSavePath == "~/Pictures/ShareX")   // preserved
        #expect(settings.upload == UploadSettings.disabled)        // injected
    }

    @Test func roundTripsDestinations() throws {
        let url = tempFile()
        let store = SettingsStore(fileURL: url)
        var s = AppSettings.default
        var config = CustomUploaderConfig(requestURL: "https://up")
        config.fileFormName = "file"
        s.upload.destinations = [UploadDestination(id: "d1", name: "Mine",
                                                   kind: .customUploader,
                                                   customUploader: config, imgurClientID: nil)]
        s.upload.activeDestinationID = "d1"
        s.upload.uploadAfterCapture = true
        try store.save(s)
        let (loaded, _) = store.loadOrDefault()
        #expect(loaded.upload.activeDestinationID == "d1")
        #expect(loaded.upload.destinations.first?.customUploader?.requestURL == "https://up")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: compile FAILURE — `cannot find 'UploadSettings' in scope`.

- [ ] **Step 3: Write `Sources/SXCore/Upload/UploadSettings.swift`**

```swift
import Foundation

public enum UploadDestinationKind: String, Codable, Sendable {
    case customUploader
    case imgur
}

public struct UploadDestination: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: UploadDestinationKind
    public var customUploader: CustomUploaderConfig?   // non-secret config; secrets → Keychain
    public var imgurClientID: String?                  // non-secret; anonymous client id

    public init(id: String, name: String, kind: UploadDestinationKind,
                customUploader: CustomUploaderConfig?, imgurClientID: String?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.customUploader = customUploader
        self.imgurClientID = imgurClientID
    }
}

public struct UploadSettings: Codable, Equatable, Sendable {
    public var uploadAfterCapture: Bool
    public var activeDestinationID: String?
    public var destinations: [UploadDestination]

    public init(uploadAfterCapture: Bool, activeDestinationID: String?,
                destinations: [UploadDestination]) {
        self.uploadAfterCapture = uploadAfterCapture
        self.activeDestinationID = activeDestinationID
        self.destinations = destinations
    }

    public static let disabled = UploadSettings(uploadAfterCapture: false,
                                                activeDestinationID: nil, destinations: [])

    public var activeDestination: UploadDestination? {
        guard let id = activeDestinationID else { return nil }
        return destinations.first { $0.id == id }
    }
}
```

- [ ] **Step 4: Modify `Sources/SXCore/AppSettings.swift`**

Add the `upload` stored property and a custom decoder that defaults it (so old JSON decodes). Replace the `AppSettings` struct body:
```swift
public struct AppSettings: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var captureSavePath: String
    public var filenameTemplate: String
    public var saveToDisk: Bool
    public var copyToClipboard: Bool
    public var showNotification: Bool
    public var hotkeys: HotkeySettings
    public var upload: UploadSettings

    public init(schemaVersion: Int, captureSavePath: String, filenameTemplate: String,
                saveToDisk: Bool, copyToClipboard: Bool, showNotification: Bool,
                hotkeys: HotkeySettings, upload: UploadSettings) {
        self.schemaVersion = schemaVersion
        self.captureSavePath = captureSavePath
        self.filenameTemplate = filenameTemplate
        self.saveToDisk = saveToDisk
        self.copyToClipboard = copyToClipboard
        self.showNotification = showNotification
        self.hotkeys = hotkeys
        self.upload = upload
    }

    // Tolerate a v1 file with no `upload` key by defaulting it (migration in SettingsStore
    // bumps the version); every other field is required as before.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        captureSavePath = try c.decode(String.self, forKey: .captureSavePath)
        filenameTemplate = try c.decode(String.self, forKey: .filenameTemplate)
        saveToDisk = try c.decode(Bool.self, forKey: .saveToDisk)
        copyToClipboard = try c.decode(Bool.self, forKey: .copyToClipboard)
        showNotification = try c.decode(Bool.self, forKey: .showNotification)
        hotkeys = try c.decode(HotkeySettings.self, forKey: .hotkeys)
        upload = try c.decodeIfPresent(UploadSettings.self, forKey: .upload) ?? .disabled
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, captureSavePath, filenameTemplate, saveToDisk,
             copyToClipboard, showNotification, hotkeys, upload
    }

    public static let `default` = AppSettings(
        schemaVersion: 2,
        captureSavePath: "~/Pictures/ShareX",
        filenameTemplate: "Screenshot_%y-%mo-%d_%h-%mi-%s",
        saveToDisk: true,
        copyToClipboard: true,
        showNotification: true,
        hotkeys: HotkeySettings(
            fullscreen: HotkeyCombo(keyCode: 20, modifiers: 2560),
            region: HotkeyCombo(keyCode: 21, modifiers: 2560),
            window: HotkeyCombo(keyCode: 23, modifiers: 2560)
        ),
        upload: .disabled
    )
}
```

- [ ] **Step 5: Modify `Sources/SXCore/SettingsStore.swift` to bump the version on load**

In `loadOrDefault()`, after a successful decode, migrate the version. Find the decode success path (the `return (try JSONDecoder().decode(...), nil)` line) and replace it with:
```swift
        do {
            var loaded = try JSONDecoder().decode(AppSettings.self, from: data)
            if loaded.schemaVersion < 2 {
                loaded.schemaVersion = 2   // `upload` already defaulted by the decoder
            }
            return (loaded, nil)
        } catch {
```
(Keep the existing `catch` block that backs up the corrupt file unchanged.)

- [ ] **Step 6: Run tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: all migration tests pass; existing SettingsStore tests still pass (they use `AppSettings.default`, now schema 2 — the `defaultsHaveExpectedHotkeys` test asserts `schemaVersion == 1`; **update that test's assertion to `== 2`** in `Tests/SXCoreTests/SettingsStoreTests.swift`).

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "Add upload settings and destinations with v1→v2 schema migration"
```

---

### Task 9: History model + SQLite history store

**Files:**
- Create: `Sources/SXCore/History/HistoryEntry.swift`
- Create: `Sources/SXCore/History/HistoryStore.swift`
- Create: `Tests/SXCoreTests/HistoryStoreTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct HistoryEntry: Equatable, Sendable, Identifiable { var id: String; var capturedAt: Date; var filePath: String?; var url: String?; var deletionURL: String?; var destinationName: String?; var uploadFailed: Bool }`
  - `final class HistoryStore` (a class; wraps an SQLite handle) — `init(fileURL: URL) throws`, `func insert(_ entry: HistoryEntry) throws`, `func recent(limit: Int) throws -> [HistoryEntry]` (newest first), `func delete(id: String) throws`, `func setURL(id: String, url: String?, deletionURL: String?, failed: Bool) throws`.
  - Uses `import SQLite3` (system library). Table `history(id TEXT PRIMARY KEY, captured_at REAL, file_path TEXT, url TEXT, deletion_url TEXT, destination TEXT, upload_failed INTEGER)`.
  - `HistoryStore` is NOT `Sendable`; it is used only on the main actor by the coordinator (Task 12).
  - Tasks 12 (and M2b's browser) consume this.

- [ ] **Step 1: Write failing tests `Tests/SXCoreTests/HistoryStoreTests.swift`**

```swift
import Foundation
import Testing
@testable import SXCore

private func tempDB() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("history.sqlite")
}

private func entry(id: String, at seconds: TimeInterval, url: String? = nil) -> HistoryEntry {
    HistoryEntry(id: id, capturedAt: Date(timeIntervalSince1970: seconds),
                 filePath: "/tmp/\(id).png", url: url, deletionURL: nil,
                 destinationName: "Test", uploadFailed: false)
}

@Suite struct HistoryStoreTests {
    @Test func insertAndReadBackNewestFirst() throws {
        let store = try HistoryStore(fileURL: tempDB())
        try store.insert(entry(id: "a", at: 100))
        try store.insert(entry(id: "b", at: 200, url: "https://x/b"))
        let rows = try store.recent(limit: 10)
        #expect(rows.map(\.id) == ["b", "a"])          // newest first
        #expect(rows.first?.url == "https://x/b")
    }

    @Test func limitCapsResults() throws {
        let store = try HistoryStore(fileURL: tempDB())
        for i in 0..<5 { try store.insert(entry(id: "e\(i)", at: TimeInterval(i))) }
        #expect(try store.recent(limit: 2).count == 2)
    }

    @Test func deleteRemovesRow() throws {
        let store = try HistoryStore(fileURL: tempDB())
        try store.insert(entry(id: "a", at: 1))
        try store.delete(id: "a")
        #expect(try store.recent(limit: 10).isEmpty)
    }

    @Test func setURLUpdatesUploadFields() throws {
        let store = try HistoryStore(fileURL: tempDB())
        try store.insert(entry(id: "a", at: 1))
        try store.setURL(id: "a", url: "https://x/a", deletionURL: "https://d/a", failed: false)
        let row = try store.recent(limit: 1).first
        #expect(row?.url == "https://x/a")
        #expect(row?.deletionURL == "https://d/a")
        #expect(row?.uploadFailed == false)
    }

    @Test func persistsAcrossReopen() throws {
        let url = tempDB()
        do { try HistoryStore(fileURL: url).insert(entry(id: "a", at: 1)) }
        let reopened = try HistoryStore(fileURL: url)
        #expect(try reopened.recent(limit: 10).map(\.id) == ["a"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/remote.sh test`
Expected: compile FAILURE — `cannot find 'HistoryStore' in scope`.

- [ ] **Step 3: Write `Sources/SXCore/History/HistoryEntry.swift`**

```swift
import Foundation

public struct HistoryEntry: Equatable, Sendable, Identifiable {
    public var id: String
    public var capturedAt: Date
    public var filePath: String?
    public var url: String?
    public var deletionURL: String?
    public var destinationName: String?
    public var uploadFailed: Bool

    public init(id: String, capturedAt: Date, filePath: String?, url: String?,
                deletionURL: String?, destinationName: String?, uploadFailed: Bool) {
        self.id = id
        self.capturedAt = capturedAt
        self.filePath = filePath
        self.url = url
        self.deletionURL = deletionURL
        self.destinationName = destinationName
        self.uploadFailed = uploadFailed
    }
}
```

- [ ] **Step 4: Write `Sources/SXCore/History/HistoryStore.swift`**

```swift
import Foundation
import SQLite3

public enum HistoryStoreError: Error, Equatable {
    case open(String)
    case exec(String)
}

/// Thin SQLite wrapper for capture/upload history. Not Sendable — use on one actor.
public final class HistoryStore {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)  // SQLITE_TRANSIENT

    public init(fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if sqlite3_open(fileURL.path, &db) != SQLITE_OK {
            throw HistoryStoreError.open(lastError)
        }
        try exec("""
            CREATE TABLE IF NOT EXISTS history (
                id TEXT PRIMARY KEY,
                captured_at REAL NOT NULL,
                file_path TEXT,
                url TEXT,
                deletion_url TEXT,
                destination TEXT,
                upload_failed INTEGER NOT NULL DEFAULT 0
            );
            """)
    }

    deinit { sqlite3_close(db) }

    public func insert(_ entry: HistoryEntry) throws {
        let sql = """
            INSERT OR REPLACE INTO history
            (id, captured_at, file_path, url, deletion_url, destination, upload_failed)
            VALUES (?,?,?,?,?,?,?);
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, entry.id)
        sqlite3_bind_double(stmt, 2, entry.capturedAt.timeIntervalSince1970)
        bindText(stmt, 3, entry.filePath)
        bindText(stmt, 4, entry.url)
        bindText(stmt, 5, entry.deletionURL)
        bindText(stmt, 6, entry.destinationName)
        sqlite3_bind_int(stmt, 7, entry.uploadFailed ? 1 : 0)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryStoreError.exec(lastError) }
    }

    public func recent(limit: Int) throws -> [HistoryEntry] {
        let sql = """
            SELECT id, captured_at, file_path, url, deletion_url, destination, upload_failed
            FROM history ORDER BY captured_at DESC LIMIT ?;
            """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var rows: [HistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(HistoryEntry(
                id: text(stmt, 0) ?? "",
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                filePath: text(stmt, 2),
                url: text(stmt, 3),
                deletionURL: text(stmt, 4),
                destinationName: text(stmt, 5),
                uploadFailed: sqlite3_column_int(stmt, 6) != 0))
        }
        return rows
    }

    public func delete(id: String) throws {
        let stmt = try prepare("DELETE FROM history WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryStoreError.exec(lastError) }
    }

    public func setURL(id: String, url: String?, deletionURL: String?, failed: Bool) throws {
        let stmt = try prepare(
            "UPDATE history SET url = ?, deletion_url = ?, upload_failed = ? WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, url)
        bindText(stmt, 2, deletionURL)
        sqlite3_bind_int(stmt, 3, failed ? 1 : 0)
        bindText(stmt, 4, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryStoreError.exec(lastError) }
    }

    // MARK: - Helpers

    private var lastError: String { String(cString: sqlite3_errmsg(db)) }

    private func exec(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw HistoryStoreError.exec(lastError) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HistoryStoreError.exec(lastError)
        }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `scripts/remote.sh test`
Expected: all HistoryStore tests pass.
(If the linker cannot find sqlite3, add `linkerSettings: [.linkedLibrary("sqlite3")]` to the `SXCore` target in `Package.swift` and re-run. On macOS the `SQLite3` module is normally resolved without this.)

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "Add SQLite history store"
```

---

### Task 10: Keychain credential store (SXApp)

**Files:**
- Create: `Sources/SXApp/KeychainCredentialStore.swift`

**Interfaces:**
- Consumes: `CredentialStore` protocol (Task 1).
- Produces: `struct KeychainCredentialStore: CredentialStore` — `init(service: String = "org.sharexmac.app")`; generic-password items keyed by `account`. Build-verified only (Keychain isn't available in the CI sandbox / can't be unit-tested headlessly).

- [ ] **Step 1: Write `Sources/SXApp/KeychainCredentialStore.swift`**

```swift
import Foundation
import Security
import SXCore

struct KeychainCredentialStore: CredentialStore {
    private let service: String
    init(service: String = "org.sharexmac.app") { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func secret(for account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw keychainError(status)
        }
        return value
    }

    func setSecret(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query(account) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
    }

    func deleteSecret(for account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func keychainError(_ status: OSStatus) -> UploadError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .transport("Keychain error: \(message)")
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `scripts/remote.sh build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "Add Keychain-backed credential store"
```

---

### Task 11: Upload service (resolve destination → uploader, inject secrets)

**Files:**
- Create: `Sources/SXApp/UploadService.swift`

**Interfaces:**
- Consumes: `UploadDestination`/`UploadDestinationKind` (Task 8), `CustomUploaderClient`/`ImgurUploader`/`Uploader` (Task 7), `URLSessionHTTPClient` (Task 3), `CredentialStore` (Task 1), `FilePart`/`UploadResult`/`UploadError`/`CustomUploaderConfig` (Tasks 1/2/4).
- Produces:
  - `struct UploadService` — `init(http: HTTPClient = URLSessionHTTPClient(), credentials: CredentialStore)`.
  - `func uploader(for destination: UploadDestination) throws -> Uploader` — builds the right client, injecting secrets from the credential store: for `.customUploader`, re-hydrates header/argument values whose stored form is the sentinel `"$keychain$"` with the secret at account `"<id>/<headerName>"`; for `.imgur`, uses `imgurClientID` (public, anonymous) directly.
  - `static func filePart(pngData: Data, filename: String) -> FilePart`
  - Task 12 consumes `UploadService`.

- [ ] **Step 1: Write `Sources/SXApp/UploadService.swift`**

```swift
import Foundation
import SXCore
import SXUpload

struct UploadService {
    static let secretSentinel = "$keychain$"
    private let http: HTTPClient
    private let credentials: CredentialStore

    init(http: HTTPClient = URLSessionHTTPClient(), credentials: CredentialStore) {
        self.http = http
        self.credentials = credentials
    }

    static func filePart(pngData: Data, filename: String) -> FilePart {
        FilePart(fieldName: "file", filename: filename, mimeType: "image/png", data: pngData)
    }

    func uploader(for destination: UploadDestination) throws -> Uploader {
        switch destination.kind {
        case .imgur:
            let clientID = destination.imgurClientID ?? ""
            guard !clientID.isEmpty else {
                throw UploadError.missingCredential("Imgur client ID not set")
            }
            return ImgurUploader(clientID: clientID, http: http)

        case .customUploader:
            guard var config = destination.customUploader else {
                throw UploadError.unsupported("Destination has no custom-uploader config")
            }
            config.headers = try injectSecrets(config.headers, destinationID: destination.id)
            config.arguments = try injectSecrets(config.arguments, destinationID: destination.id)
            return CustomUploaderClient(config: config, http: http)
        }
    }

    /// Replace any value equal to the sentinel with the secret stored under
    /// "<destinationID>/<key>"; throw if the secret is missing.
    private func injectSecrets(_ dict: [String: String],
                               destinationID: String) throws -> [String: String] {
        var result = dict
        for (key, value) in dict where value == Self.secretSentinel {
            let account = "\(destinationID)/\(key)"
            guard let secret = try credentials.secret(for: account) else {
                throw UploadError.missingCredential(account)
            }
            result[key] = secret
        }
        return result
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `scripts/remote.sh build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "Add upload service resolving destinations to uploaders"
```

---

### Task 12: Pipeline/coordinator upload integration + after-upload chain

**Files:**
- Modify: `Sources/SXCore/AfterCapturePipeline.swift` (extend `PipelineEffects` with URL/history hooks)
- Modify: `Sources/SXApp/AppPipelineEffects.swift` (implement the new hooks)
- Modify: `Sources/SXApp/CaptureCoordinator.swift` (async upload after deliver)
- Modify: `Sources/SXApp/AppDelegate.swift` (construct coordinator with upload deps + history store)

**Interfaces:**
- Consumes: `UploadService` (Task 11), `HistoryStore`/`HistoryEntry` (Task 9), `KeychainCredentialStore` (Task 10), `UploadDestination`/`UploadSettings` (Task 8), existing coordinator/effects.
- Produces:
  - `PipelineEffects` gains `func copyTextToClipboard(_ text: String)` and `func notify(title:body:url:)` (a URL-click variant that opens the URL).
  - `CaptureCoordinator` gains `init(settingsStore:effects:uploadService:historyStore:)` and, after a successful `deliver`, runs an async upload of the active destination when `settings.upload.uploadAfterCapture` is true, recording a history row first (local) then updating it with the URL (or failure).
  - Local-first invariant preserved: the history row and the upload both happen after the synchronous disk save inside `deliver`.

- [ ] **Step 1: Extend `PipelineEffects` in `Sources/SXCore/AfterCapturePipeline.swift`**

Add to the protocol (after `notify(title:body:fileURL:)`):
```swift
    func copyTextToClipboard(_ text: String)
    func notifyURL(title: String, body: String, url: String)
```

- [ ] **Step 2: Implement the new hooks in `Sources/SXApp/AppPipelineEffects.swift`**

Add these methods to `AppPipelineEffects`:
```swift
    func copyTextToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if !pb.setString(text, forType: .string) {
            AppLog.log("Pasteboard text write failed")
        }
    }

    func notifyURL(title: String, body: String, url: String) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["url": url]
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Notification error: \(error)") }
        }
    }
```
And in the existing `userNotificationCenter(_:didReceive:withCompletionHandler:)` delegate method, add URL handling before the existing `path` handling:
```swift
        if let urlString = userInfo["url"] as? String, let url = URL(string: urlString) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            completionHandler()
            return
        }
```

Also update the test mock so `SXCore` still compiles: in `Tests/SXCoreTests/AfterCapturePipelineTests.swift`, add these two methods to `MockEffects` (record calls so future tests can assert on them):
```swift
    var textCopies: [String] = []
    var urlNotifications: [(String, String)] = []   // (body, url)
    func copyTextToClipboard(_ text: String) {
        callOrder.append("copyText"); textCopies.append(text)
    }
    func notifyURL(title: String, body: String, url: String) {
        callOrder.append("notifyURL"); urlNotifications.append((body, url))
    }
```
(The existing pipeline tests don't call these, so `callOrder` for those tests is unaffected.)

- [ ] **Step 3: Wire upload into `Sources/SXApp/CaptureCoordinator.swift`**

Add stored properties and update `init`:
```swift
    private let uploadService: UploadService
    private let historyStore: HistoryStore?
```
Replace the initializer with:
```swift
    init(settingsStore: SettingsStore, effects: AppPipelineEffects,
         uploadService: UploadService, historyStore: HistoryStore?) {
        self.settingsStore = settingsStore
        self.effects = effects
        self.uploadService = uploadService
        self.historyStore = historyStore
    }
```
In `deliver(image:appName:)`, after the successful pipeline `process` call (where it currently logs "Capture delivered" and `return true`), insert a call to record + upload BEFORE `return true`:
```swift
            recordAndMaybeUpload(settings: settings, savedURL: result.savedURL,
                                 pngData: png, capturedAt: artifact.capturedAt)
```
Then add the new method (uses `png` — rename the local `png` constant if needed so it is in scope; it is the `ImageEncoder.png(from:)` result already bound at the top of `deliver`):
```swift
    /// Records a history row for the capture, then (if configured) uploads
    /// asynchronously and updates the row with the URL or a failure marker.
    /// Runs after the synchronous disk save, preserving the local-first invariant.
    private func recordAndMaybeUpload(settings: AppSettings, savedURL: URL?,
                                      pngData: Data, capturedAt: Date) {
        let entryID = UUID().uuidString
        let destination = settings.upload.activeDestination
        let willUpload = settings.upload.uploadAfterCapture && destination != nil

        if let store = historyStore {
            let entry = HistoryEntry(id: entryID, capturedAt: capturedAt,
                                     filePath: savedURL?.path, url: nil, deletionURL: nil,
                                     destinationName: destination?.name,
                                     uploadFailed: false)
            do { try store.insert(entry) } catch { AppLog.log("History insert failed: \(error)") }
        }

        guard willUpload, let destination else { return }
        let filename = savedURL?.lastPathComponent ?? "capture.png"
        Task { @MainActor in
            do {
                let uploader = try uploadService.uploader(for: destination)
                let file = UploadService.filePart(pngData: pngData, filename: filename)
                let result = try await uploader.upload(file)
                AppLog.log("Upload succeeded: \(result.url)")
                effects.copyTextToClipboard(result.url)
                effects.notifyURL(title: "Uploaded", body: result.url, url: result.url)
                try? historyStore?.setURL(id: entryID, url: result.url,
                                          deletionURL: result.deletionURL, failed: false)
            } catch {
                AppLog.log("Upload failed: \(error)")
                effects.notify(title: "Upload failed",
                               body: "\(error). Local file kept.", fileURL: savedURL)
                try? historyStore?.setURL(id: entryID, url: nil, deletionURL: nil, failed: true)
            }
        }
    }
```

- [ ] **Step 4: Construct the coordinator with the new deps in `Sources/SXApp/AppDelegate.swift`**

In `applicationDidFinishLaunching`, replace the coordinator construction:
```swift
        let historyStore = try? HistoryStore(
            fileURL: SettingsStore.defaultFileURL.deletingLastPathComponent()
                .appendingPathComponent("history.sqlite"))
        if historyStore == nil { AppLog.log("History store unavailable; captures won't be recorded") }
        let uploadService = UploadService(credentials: KeychainCredentialStore())
        let coordinator = CaptureCoordinator(settingsStore: store, effects: effects,
                                             uploadService: uploadService,
                                             historyStore: historyStore)
```
(Add `import SXCore` symbols as needed — `HistoryStore` is in SXCore, already imported.)

- [ ] **Step 5: Build and run full tests**

Run: `scripts/remote.sh test`
Expected: build succeeds; all tests pass (no test asserts the new coordinator upload path — it's exercised in the live smoke, Task 13).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "Upload after capture: copy URL, notify, record history (local-first)"
```

---

### Task 13: `.sxcu` import, menu, CI/docs, live smoke

**Files:**
- Create: `Sources/SXApp/SxcuImporter.swift`
- Modify: `Sources/SXApp/AppDelegate.swift` (menu items + open-file handling)
- Modify: `Resources/Info.plist` (declare the `.sxcu` document type)
- Modify: `docs/porting-map.md`, `docs/smoke-m1.md` (→ add M2a rows), `README.md`
- Create: `docs/smoke-m2a.md`

**Interfaces:**
- Consumes: `CustomUploaderConfig` (Task 4), `UploadDestination`/`UploadSettings` (Task 8), `SettingsStore`, `KeychainCredentialStore` (Task 10), `UploadService.secretSentinel` (Task 11).
- Produces:
  - `enum SxcuImporter { static func makeDestination(from data: Data, id: String, credentials: CredentialStore) throws -> UploadDestination }` — parses the `.sxcu`, moves each header/argument value that looks like a secret (a non-empty value under a header named `Authorization`/`*Token*`/`*Key*`, case-insensitive) into the Keychain at `"<id>/<key>"`, replacing the stored value with `UploadService.secretSentinel`.
  - AppDelegate: "Import .sxcu…" menu item (NSOpenPanel), open-file handling (`application(_:openFile:)`), and an "Upload after capture" toggle + destination submenu.

- [ ] **Step 1: Write `Sources/SXApp/SxcuImporter.swift`**

```swift
import Foundation
import SXCore

enum SxcuImporter {
    /// Heuristic: header/argument keys that typically carry secrets.
    private static func isSecretKey(_ key: String) -> Bool {
        let k = key.lowercased()
        return k == "authorization" || k.contains("token") || k.contains("apikey")
            || k.contains("api-key") || k.contains("secret") || k.contains("key")
    }

    static func makeDestination(from data: Data, id: String,
                                credentials: CredentialStore) throws -> UploadDestination {
        var config = try CustomUploaderConfig.parse(data)

        func stripSecrets(_ dict: [String: String]) throws -> [String: String] {
            var out = dict
            for (key, value) in dict where isSecretKey(key) && !value.isEmpty {
                try credentials.setSecret(value, for: "\(id)/\(key)")
                out[key] = UploadService.secretSentinel
            }
            return out
        }
        config.headers = try stripSecrets(config.headers)
        config.arguments = try stripSecrets(config.arguments)

        return UploadDestination(id: id, name: config.name ?? "Custom uploader",
                                 kind: .customUploader, customUploader: config,
                                 imgurClientID: nil)
    }
}
```

- [ ] **Step 2: Add menu items + import handling in `Sources/SXApp/AppDelegate.swift`**

Add `import UniformTypeIdentifiers` at the top of the file (needed for `UTType` below).

Add to `buildMenu()` (before the Quit separator):
```swift
        menu.addItem(.separator())
        menu.addItem(menuItem("Import .sxcu…", #selector(importSxcu)))
        let uploadToggle = menuItem("Upload After Capture", #selector(toggleUploadAfterCapture))
        uploadToggle.state = currentUploadAfterCapture() ? .on : .off
        menu.addItem(uploadToggle)
```
Add these methods:
```swift
    private func currentUploadAfterCapture() -> Bool {
        SettingsStore(fileURL: SettingsStore.defaultFileURL).loadOrDefault().0.upload.uploadAfterCapture
    }

    @objc private func importSxcu() {
        // runModal (synchronous, @MainActor) avoids the Swift 6 concurrency friction
        // of an escaping completion closure; UTType filtering avoids the deprecated
        // `allowedFileTypes` API (which would emit a build warning).
        let panel = NSOpenPanel()
        if let sxcuType = UTType(filenameExtension: "sxcu") {
            panel.allowedContentTypes = [sxcuType]
        } else {
            panel.allowsOtherFileTypes = true
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSxcu(from: url)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        importSxcu(from: URL(fileURLWithPath: filename))
        return true
    }

    private func importSxcu(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let store = SettingsStore(fileURL: SettingsStore.defaultFileURL)
            var (settings, _) = store.loadOrDefault()
            let id = UUID().uuidString
            let destination = try SxcuImporter.makeDestination(
                from: data, id: id, credentials: KeychainCredentialStore())
            settings.upload.destinations.append(destination)
            settings.upload.activeDestinationID = id      // make the freshly imported one active
            try store.save(settings)
            AppLog.log("Imported .sxcu destination '\(destination.name)' (id \(id))")
            effects.notify(title: "Uploader imported",
                           body: "\(destination.name) is now the active destination.",
                           fileURL: nil)
            rebuildMenu()
        } catch {
            AppLog.log("Import .sxcu failed: \(error)")
            effects.notify(title: "Import failed", body: "\(error)", fileURL: nil)
        }
    }

    @objc private func toggleUploadAfterCapture() {
        let store = SettingsStore(fileURL: SettingsStore.defaultFileURL)
        var (settings, _) = store.loadOrDefault()
        settings.upload.uploadAfterCapture.toggle()
        try? store.save(settings)
        AppLog.log("Upload after capture: \(settings.upload.uploadAfterCapture)")
        rebuildMenu()
    }

    private func rebuildMenu() {
        statusItem?.setMenu(buildMenu())
    }
```
Add a `setMenu` method to `StatusItemController` (in `Sources/SXApp/StatusItemController.swift`):
```swift
    func setMenu(_ menu: NSMenu) {
        statusItem.menu = menu
    }
```

- [ ] **Step 3: Declare the `.sxcu` document type in `Resources/Info.plist`**

Add before the closing `</dict>`:
```xml
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>ShareX Custom Uploader</string>
            <key>CFBundleTypeExtensions</key><array><string>sxcu</string></array>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
        </dict>
    </array>
```

- [ ] **Step 4: Build + full tests**

Run: `scripts/remote.sh test`
Expected: build clean, all tests pass.

- [ ] **Step 5: Write `docs/smoke-m2a.md`**

```markdown
# M2a manual smoke checklist

Run on the Mac after `scripts/remote.sh run`. Diagnostics: `~/Library/Logs/ShareX-Mac.log`.

- [ ] Menu shows "Import .sxcu…" and "Upload After Capture" (with a checkmark state)
- [ ] Import a real .sxcu (e.g. an Imgur or self-hosted config) → "Uploader imported" notification; it becomes the active destination
- [ ] Toggle "Upload After Capture" on
- [ ] Capture fullscreen (⌥⇧3) → local file still saved to ~/Pictures/ShareX (local-first), then an "Uploaded" notification appears with the URL
- [ ] Clipboard holds the URL (⌘V into a text field) — not the image — after a successful upload
- [ ] Clicking the "Uploaded" notification opens the URL in the browser
- [ ] The uploaded image is actually reachable at the URL
- [ ] Turn off Wi‑Fi, capture → local file saved, "Upload failed … Local file kept" notification, no clipboard URL (capture not lost)
- [ ] history.sqlite exists at ~/Library/Application Support/ShareX-Mac/ and has rows (verify: `sqlite3 ~/Library/Application\ Support/ShareX-Mac/history.sqlite 'select url,upload_failed from history'`)
- [ ] Import a .sxcu with an Authorization header → the header value is NOT present in ~/Library/Application Support/ShareX-Mac/settings.json (it's `$keychain$`); the secret is in the login keychain
- [ ] Import a malformed / XML-body .sxcu → clear "Import failed" notification, no crash
```

- [ ] **Step 6: Update `docs/porting-map.md`, `docs/smoke-m1.md`, `README.md`**

- In `docs/porting-map.md`, add rows for the SXUpload types and the SXCore upload/history types, each mapped to `ShareX.UploadersLib` `CustomUploaderItem.cs`/`CustomUploaderParser`/`URLHelpers`/history equivalents; mark `KeychainCredentialStore`, `HistoryStore` (SQLite is ShareX-parallel via `ShareX.HistoryLib`), and `UploadService` appropriately.
- In `README.md`, update the status line to: `**Status:** M2a — capture + share: after-capture upload to a ShareX .sxcu custom uploader or Imgur, copy-URL, local SQLite history. Design: docs/superpowers/specs/2026-07-10-sharex-mac-design.md`.
- In `docs/smoke-m1.md`, add a one-line pointer: "M2a upload smoke: see docs/smoke-m2a.md".

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "Add .sxcu import, upload menu, doc updates for M2a"
```

- [ ] **Step 8: Live smoke (controller-run with the user)**

The controller deploys via `scripts/remote.sh run` and walks the user through `docs/smoke-m2a.md` — importing a real `.sxcu`, capturing with upload on, verifying the URL lands on the clipboard and the local file survives an offline failure. This is the M2a exit gate.

---

## Notes for the executor

- **Local-first is the invariant that matters most here.** Every path in Task 12 must save to disk before uploading; the upload is a fire-and-forget async task that never blocks or gates the local save.
- **Secrets never touch settings.json.** Task 13's importer moves them to the Keychain and leaves the sentinel; Task 11 rehydrates them at upload time. Verify this in the smoke (settings.json must not contain the token).
- **`.sxcu` fidelity is corpus-driven.** The fixtures cover the common multipart+JSON/regex shape. If a real config uses request-side `{input}`/`{prompt}` placeholders (interactive), that is out of M2a scope — the parse succeeds but the upload will send the literal token; note this as a known limitation, don't silently paper over it.
- SFTP/FTP (M5), S3 + SigV4, and the SwiftUI history browser window (M2b) are explicitly NOT in this plan.
