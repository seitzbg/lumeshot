import AppKit
import LumeshotCore
import LumeshotUpload
import Testing
@testable import LumeshotApp

@MainActor
final class CaptureTestEffects: PipelineEffects {
    var clipboardChangeCount = 0
    var image: Data?
    var text: String?
    var order: [String] = []
    var onUploadFinished: ((String) -> Void)?
    var onURLNotification: (() -> Void)?

    func fileExists(at url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func writeFile(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        order.append("save")
    }
    func copyImageToClipboard(_ pngData: Data) {
        clipboardChangeCount += 1
        image = pngData
        text = nil
        order.append("image")
    }
    func copyTextToClipboard(_ value: String) {
        clipboardChangeCount += 1
        text = value
        image = nil
        order.append("url")
        onUploadFinished?("url")
    }
    func notify(title: String, body: String, fileURL: URL?) {
        if title == "Upload failed" || title == "Choose an active uploader" { onUploadFinished?(title) }
    }
    func notifyURL(title: String, body: String, url: String) { onURLNotification?() }
}

private actor UploadHTTP: HTTPClient {
    var requests: [PreparedRequest] = []
    let fail: Bool
    init(fail: Bool) { self.fail = fail }

    func send(_ request: PreparedRequest) async throws -> HTTPResponse {
        requests.append(request)
        if fail { throw UploadError.transport("Offline") }
        return HTTPResponse(status: 200, headers: [:],
            body: Data(#"{"data":{"link":"https://i.imgur.com/capture.png","deletehash":"delete"}}"#.utf8))
    }
}

private actor DelayedUploadHTTP: HTTPClient {
    let started: AsyncStream<Void>.Continuation
    private var response: CheckedContinuation<HTTPResponse, Error>?

    init(started: AsyncStream<Void>.Continuation) { self.started = started }

    func send(_ request: PreparedRequest) async throws -> HTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            response = continuation
            started.yield(())
            started.finish()
        }
    }

    func succeed() {
        response?.resume(returning: HTTPResponse(status: 200, headers: [:],
            body: Data(#"{"data":{"link":"https://i.imgur.com/earlier.png","deletehash":"delete"}}"#.utf8)))
        response = nil
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct CaptureClipboardTests {
    @Test(arguments: [false, true])
    func delayedUploadPreservesNewerClipboardContents(newCapture: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        var settings = AppSettings.default
        settings.captureSavePath = directory.path
        settings.upload = UploadSettings(uploadAfterCapture: true, activeDestinationID: "a", destinations: [
            UploadDestination(id: "a", name: "Uploader", kind: .imgur, imgurClientID: "CLIENT"),
        ])
        try store.save(settings)
        let history = try HistoryStore(fileURL: directory.appendingPathComponent("history.sqlite"))
        let (started, startContinuation) = AsyncStream<Void>.makeStream()
        let http = DelayedUploadHTTP(started: startContinuation)
        let effects = CaptureTestEffects()
        let coordinator = CaptureCoordinator(settingsStore: store, effects: effects,
            uploadService: UploadService(http: http, credentials: UnusedCredentials()), historyStore: history)
        let context = try #require(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let (finished, finishContinuation) = AsyncStream<Void>.makeStream()
        effects.onURLNotification = { finishContinuation.yield(()); finishContinuation.finish() }
        defer { startContinuation.finish(); finishContinuation.finish() }

        coordinator.deliver(image: image, appName: nil)
        var startIterator = started.makeAsyncIterator()
        _ = await startIterator.next()
        if newCapture {
            settings.upload.uploadAfterCapture = false
            try store.save(settings)
            coordinator.deliver(image: image, appName: nil)
        } else {
            effects.copyTextToClipboard("Text copied in another app")
        }
        let expectedImage = effects.image
        let expectedText = effects.text
        let expectedOrder = effects.order
        await http.succeed()
        var finishIterator = finished.makeAsyncIterator()
        _ = await finishIterator.next()

        #expect(effects.image == expectedImage)
        #expect(effects.text == expectedText)
        #expect(effects.order == expectedOrder)
        #expect(try history.recent(limit: 10).contains { $0.url == "https://i.imgur.com/earlier.png" })
    }

    @Test(arguments: [false, true], [false, true])
    func clipboardFollowsUploadMode(upload: Bool, failure: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        var settings = AppSettings.default
        settings.captureSavePath = directory.path
        settings.showNotification = false
        settings.upload = UploadSettings(uploadAfterCapture: upload, activeDestinationID: "b", destinations: [
            UploadDestination(id: "a", name: "First", kind: .imgur, imgurClientID: "FIRST"),
            UploadDestination(id: "b", name: "Active", kind: .imgur, imgurClientID: "ACTIVE"),
        ])
        try store.save(settings)
        // Stale clipboard preferences must not override the current upload mode.
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        object["copyToClipboard"] = false
        var uploadObject = try #require(object["upload"] as? [String: Any])
        uploadObject["afterUploadClipboard"] = "image"
        object["upload"] = uploadObject
        try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)

        let http = UploadHTTP(fail: failure)
        let effects = CaptureTestEffects()
        let coordinator = CaptureCoordinator(settingsStore: store, effects: effects,
            uploadService: UploadService(http: http, credentials: UnusedCredentials()), historyStore: nil)
        let context = try #require(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let (events, continuation) = AsyncStream<String>.makeStream()
        effects.onUploadFinished = { continuation.yield($0); continuation.finish() }
        defer { continuation.finish() }
        coordinator.deliver(image: image, appName: nil)
        #expect(effects.order == ["save", "image"])
        #expect(effects.image != nil)

        if upload {
            var iterator = events.makeAsyncIterator()
            #expect(await iterator.next() == (failure ? "Upload failed" : "url"))
            let requests = await http.requests
            #expect(requests.count == 1)
            #expect(requests.first?.headers["Authorization"] == "Client-ID ACTIVE")
        } else {
            #expect(await http.requests.isEmpty)
        }
        if upload && !failure {
            #expect(effects.text == "https://i.imgur.com/capture.png")
            #expect(effects.image == nil)
            #expect(effects.order == ["save", "image", "url"])
        } else {
            #expect(effects.text == nil)
            #expect(effects.image != nil)
        }
    }
}
