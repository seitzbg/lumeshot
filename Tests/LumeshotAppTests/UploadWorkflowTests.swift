import AppKit
import ImageIO
import Testing
import LumeshotCore
import LumeshotUpload
@testable import LumeshotApp

private actor WorkflowHTTP: HTTPClient {
    var requests: [PreparedRequest] = []
    let response: HTTPResponse
    init(status: Int = 200, body: String = #"{"data":{"link":"https://example.com/test.png","deletehash":"delete"}}"#) {
        response = HTTPResponse(status: status, headers: [:], body: Data(body.utf8))
    }
    func send(_ request: PreparedRequest) async throws -> HTTPResponse {
        requests.append(request)
        return response
    }
}

private struct PicsurTestCredentials: CredentialStore {
    func secret(for account: String) throws -> String? {
        account == "picsur-test/picsur/apiKey" ? "saved-api-key" : nil
    }
    func setSecret(_ value: String, for account: String) throws {}
    func deleteSecret(for account: String) throws {}
}

@MainActor
private struct HistoryFixture {
    let directory: URL
    let store: HistoryStore
    let settingsStore: SettingsStore
    let file: URL
    var destination = UploadDestination(id: "uploader", name: "Test", kind: .imgur, imgurClientID: "client")

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try HistoryStore(fileURL: directory.appendingPathComponent("history.sqlite"))
        settingsStore = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        file = directory.appendingPathComponent("capture.png")
        try Data([1, 2, 3]).write(to: file)
        var settings = AppSettings.default
        settings.upload = settings.upload.addingOrUpdating(destination)
        try settingsStore.save(settings)
    }

    func entry(url: String? = nil) -> HistoryEntry {
        HistoryEntry(id: "capture", capturedAt: Date(timeIntervalSince1970: 100), filePath: file.path,
                     url: url, deletionURL: url == nil ? nil : "https://example.com/delete-original",
                     destinationName: destination.name, uploadFailed: url == nil, destinationID: destination.id)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@Suite @MainActor
struct UploadWorkflowTests {
    private var picsurDestination: UploadDestination {
        UploadDestination(id: "picsur-test", name: "Picsur test", kind: .picsur,
                          picsurConfig: PicsurConfig(host: "https://pics.example.com/gallery"))
    }
    private let picsurImageID = "917fe5d7-261e-40d7-a135-dfbf9cf9bd11"
    private var picsurResult: UploadResult {
        let config = picsurDestination.picsurConfig!
        return UploadResult(url: config.url(id: picsurImageID),
                            deletionURL: config.deletionURL(id: picsurImageID, deleteKey: "image-delete-key"))
    }
    private var picsurDeleteConfirmation: String {
        "{\"success\":true,\"data\":{\"id\":\"\(picsurImageID)\"}}"
    }

    @Test func picsurTestDeletionUsesSavedKeyAndJSONEndpoint() async throws {
        let http = WorkflowHTTP(body: picsurDeleteConfirmation)
        let model = UploaderTestModel(destination: picsurDestination, http: http,
                                      credentials: PicsurTestCredentials()) { _, _ in picsurResult }
        await model.run()
        #expect(await http.requests.isEmpty)
        await model.deleteTestUpload()
        #expect(model.deleted && model.error == nil)
        let request = try #require(await http.requests.first)
        #expect(request.method == .post)
        #expect(request.url == "https://pics.example.com/gallery/api/image/delete/key")
        #expect(request.headers["Authorization"] == "Api-Key saved-api-key")
        #expect(request.contentType == "application/json")
        let body = try JSONDecoder().decode([String: String].self, from: #require(request.body))
        #expect(body == ["id": picsurImageID, "key": "image-delete-key"])
        await model.deleteTestUpload()
        #expect(await http.requests.count == 1)
    }

    @Test func picsurHistoryDeletionUsesOriginalDestinationAfterRename() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        var destination = picsurDestination
        destination.name = "Renamed Picsur"
        var settings = fixture.settingsStore.loadOrDefault().0
        settings.upload = settings.upload.addingOrUpdating(destination)
        try fixture.settingsStore.save(settings)
        var entry = fixture.entry(url: picsurResult.url)
        entry.deletionURL = picsurResult.deletionURL
        entry.destinationID = destination.id
        entry.destinationName = "Old name"
        try fixture.store.insert(entry)
        let http = WorkflowHTTP(body: picsurDeleteConfirmation)
        let model = HistoryModel(store: fixture.store, http: http, settingsStore: fixture.settingsStore,
                                 effects: CaptureTestEffects(), credentials: PicsurTestCredentials())
        await model.deleteRemote(entry)
        #expect(model.deleteError == nil)
        #expect(await http.requests.first?.headers["Authorization"] == "Api-Key saved-api-key")
        let row = try #require(fixture.store.all(limit: 10).first)
        #expect(row.url == nil && row.deletionURL == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    @Test(arguments: [403, 404, 410, 500, 200])
    func picsurDeletionFailuresKeepTestLink(status: Int) async {
        // HTML with 200 is what the old browser deletion route could return,
        // even after a failed deletion. It must never count as confirmation.
        let http = WorkflowHTTP(status: status, body: "<html>secret-server-detail</html>")
        let model = UploaderTestModel(destination: picsurDestination, http: http,
                                      credentials: PicsurTestCredentials()) { _, _ in picsurResult }
        await model.run()
        await model.deleteTestUpload()
        #expect(!model.deleted && model.error != nil)
        #expect(model.result == picsurResult)
        #expect(model.error?.contains("secret-server-detail") == false)
    }

    @Test(arguments: [#"{"success":false,"data":{"id":"917fe5d7-261e-40d7-a135-dfbf9cf9bd11"}}"#,
                      #"{"success":true,"data":{"id":"another-image"}}"#])
    func picsurDeletionRequiresConfirmationOfTheSameImage(body: String) async {
        let model = UploaderTestModel(destination: picsurDestination, http: WorkflowHTTP(body: body),
                                      credentials: PicsurTestCredentials()) { _, _ in picsurResult }
        await model.run()
        await model.deleteTestUpload()
        #expect(!model.deleted && model.error != nil)
    }

    @Test(arguments: ["changed-server", "missing-destination", "missing-credentials", "bad-link"])
    func picsurDeletionNeverSendsWithMismatchedSettings(scenario: String) async throws {
        let http = WorkflowHTTP(body: picsurDeleteConfirmation)
        let service = RemoteDeletionService(http: http,
            credentials: scenario == "missing-credentials" ? UnusedCredentials() : PicsurTestCredentials())
        var destination: UploadDestination? = picsurDestination
        if scenario == "changed-server" { destination?.picsurConfig = PicsurConfig(host: "https://another.example.com") }
        if scenario == "missing-destination" { destination = nil }
        let link = scenario == "bad-link"
            ? "https://pics.example.com.evil.example/api/image/delete/\(picsurImageID)/key"
            : picsurResult.deletionURL!
        do { try await service.delete(link, destination: destination); Issue.record("Expected rejection") }
        catch {}
        #expect(await http.requests.isEmpty)
    }

    @Test func retryKeepsTheFileAndOriginalTimestampAndCopiesTheLink() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        let original = fixture.entry()
        try fixture.store.insert(original)
        let effects = CaptureTestEffects()
        var sent: FilePart?
        let model = HistoryModel(store: fixture.store, settingsStore: fixture.settingsStore, effects: effects) { part, _ in
            sent = part
            return UploadResult(url: "https://example.com/new", deletionURL: "https://example.com/delete-new")
        }
        await model.upload(original, to: fixture.destination)
        let row = try #require(fixture.store.all(limit: 10).first)
        #expect(try fixture.store.all(limit: 10).count == 1)
        #expect(row.id == original.id)
        #expect(row.capturedAt == original.capturedAt)
        #expect(row.destinationID == fixture.destination.id)
        #expect(row.url == "https://example.com/new")
        #expect(!row.uploadFailed)
        #expect(effects.text == row.url)
        #expect(sent?.source == .file(fixture.file, byteCount: 3))
        #expect(try Data(contentsOf: fixture.file) == Data([1, 2, 3]))
    }

    @Test func reuploadPreservesThePreviousLinkAndDeletionToken() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        let original = fixture.entry(url: "https://example.com/original")
        try fixture.store.insert(original)
        let model = HistoryModel(store: fixture.store, effects: CaptureTestEffects()) { _, _ in
            UploadResult(url: "https://example.com/another")
        }
        await model.upload(original, to: fixture.destination)
        let rows = try fixture.store.all(limit: 10)
        #expect(rows.count == 2)
        #expect(rows.first(where: { $0.id == original.id }) == original)
        #expect(rows.contains { $0.id != original.id && $0.url == "https://example.com/another" })
    }

    @Test func failedRetryKeepsHistoryAndDoesNotExposeServerResponse() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        try fixture.store.insert(fixture.entry())
        let model = HistoryModel(store: fixture.store, effects: CaptureTestEffects()) { _, _ in
            throw UploadError.http(status: 401, body: "secret=do-not-display")
        }
        await model.upload(fixture.entry(), to: fixture.destination)
        #expect(try fixture.store.all(limit: 10).first?.uploadFailed == true)
        #expect(model.actionError?.contains("credentials") == true)
        #expect(model.actionError?.contains("do-not-display") == false)
        #expect(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    @Test func retryPreservesNewerClipboardContent() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        let effects = CaptureTestEffects()
        let model = HistoryModel(store: fixture.store, effects: effects) { _, _ in
            effects.copyTextToClipboard("newer copy")
            return UploadResult(url: "https://example.com/upload")
        }
        await model.upload(fixture.entry(), to: fixture.destination)
        #expect(effects.text == "newer copy")
        #expect(try fixture.store.all(limit: 10).first?.url == "https://example.com/upload")
    }

    @Test func missingFileNeverStartsAnUpload() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.removeItem(at: fixture.file)
        var calls = 0
        let model = HistoryModel(store: fixture.store, effects: CaptureTestEffects()) { _, _ in
            calls += 1
            return UploadResult(url: "https://example.com/upload")
        }
        await model.upload(fixture.entry(), to: fixture.destination)
        #expect(calls == 0)
        #expect(model.actionError != nil)
    }

    @Test func inFlightCaptureCannotBeRetriedOrRemoved() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        let entry = fixture.entry()
        try fixture.store.insert(entry)
        let operation = UploadActivity.shared.begin(filename: "capture.png", destination: "Test", filePath: fixture.file.path)
        defer { UploadActivity.shared.finish(operation, url: "https://example.com/in-flight") }
        var calls = 0
        let model = HistoryModel(store: fixture.store, effects: CaptureTestEffects()) { _, _ in
            calls += 1
            return UploadResult(url: "https://example.com/duplicate")
        }
        #expect(model.isBusy(entry))
        await model.upload(entry, to: fixture.destination)
        model.removeFromHistory(entry)
        #expect(calls == 0)
        #expect(try fixture.store.all(limit: 10).first == entry)
    }

    @Test func remoteDeleteAndHistoryRemovalAreSeparate() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        let original = fixture.entry(url: "https://example.com/original")
        try fixture.store.insert(original)
        let http = WorkflowHTTP()
        let model = HistoryModel(store: fixture.store, http: http, effects: CaptureTestEffects())
        await model.deleteRemote(original)
        let row = try #require(fixture.store.all(limit: 10).first)
        #expect(row.url == nil && row.deletionURL == nil)
        #expect(row.id == original.id)
        #expect(FileManager.default.fileExists(atPath: fixture.file.path))
        #expect(await http.requests.count == 1)
        #expect(await http.requests.first?.url == original.deletionURL)
        model.removeFromHistory(row)
        #expect(try fixture.store.all(limit: 10).isEmpty)
        #expect(await http.requests.count == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    @Test func failedRemoteDeletionKeepsItsToken() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        let original = fixture.entry(url: "https://example.com/original")
        try fixture.store.insert(original)
        let model = HistoryModel(store: fixture.store, http: WorkflowHTTP(status: 503), effects: CaptureTestEffects())
        await model.deleteRemote(original)
        #expect(try fixture.store.all(limit: 10).first == original)
        #expect(model.deleteError != nil)
    }

    @Test func destinationIdentitySurvivesRenameAndDoesNotGuessAfterRemoval() throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        var settings = fixture.settingsStore.loadOrDefault().0
        settings.upload.destinations[0].name = "Renamed uploader"
        try fixture.settingsStore.save(settings)
        let model = HistoryModel(store: fixture.store, settingsStore: fixture.settingsStore, effects: CaptureTestEffects())
        #expect(model.preferredDestination(for: fixture.entry()) == fixture.destination.id)
        settings.upload.destinations[0].id = "replacement"
        settings.upload.destinations[0].name = fixture.destination.name
        try fixture.settingsStore.save(settings)
        #expect(model.preferredDestination(for: fixture.entry()) == nil)
    }

    @Test func uploaderTestOnlySendsGeneratedPNGAfterRun() async throws {
        let destination = UploadDestination(id: "test", name: "Test", kind: .imgur)
        var parts: [FilePart] = []
        let model = UploaderTestModel(destination: destination) { part, _ in
            parts.append(part)
            return UploadResult(url: "https://example.com/test")
        }
        #expect(parts.isEmpty)
        await model.run()
        await model.run() // Does not leave another remote file after success.
        #expect(parts.count == 1)
        let part = try #require(parts.first)
        #expect(part.filename.hasPrefix("lumeshot-test-"))
        #expect(part.mimeType == "image/png")
        let image = try #require(CGImageSourceCreateWithData(part.readData() as CFData, nil))
        let cg = try #require(CGImageSourceCreateImageAtIndex(image, 0, nil))
        #expect(cg.width == 400 && cg.height == 200)
        #expect(model.result?.url == "https://example.com/test")
        #expect(!model.isRunning)
    }

    @Test func uploaderTestCanRetryFailureAndDeleteOnlyWhenAsked() async throws {
        let destination = UploadDestination(id: "test", name: "Test", kind: .customUploader)
        let http = WorkflowHTTP()
        var attempts = 0
        let model = UploaderTestModel(destination: destination, http: http) { _, _ in
            attempts += 1
            if attempts == 1 { throw UploadError.http(status: 401, body: "credential=private") }
            return UploadResult(url: "https://example.com/test", deletionURL: "https://example.com/delete-test")
        }
        await model.run()
        #expect(model.error?.contains("credentials") == true)
        #expect(model.error?.contains("private") == false)
        #expect(!model.isRunning)
        await model.run()
        #expect(model.result != nil && model.error == nil)
        #expect(await http.requests.isEmpty)
        await model.deleteTestUpload()
        #expect(model.deleted)
        #expect(await http.requests.count == 1)
        #expect(await http.requests.first?.url == "https://example.com/delete-test")
    }

    @Test func uploadServiceTracksSuccessAndFailure() async throws {
        let activity = UploadActivity()
        let destination = UploadDestination(id: "test", name: "Test", kind: .imgur, imgurClientID: "client")
        let part = FilePart(fieldName: "file", filename: "test.png", mimeType: "image/png", data: Data([1]))
        let success = UploadService(http: WorkflowHTTP(), credentials: UnusedCredentials(), activity: activity)
        _ = try await success.upload(part: part, destination: destination)
        #expect(activity.running.isEmpty)
        #expect(activity.summary == "Upload complete")
        activity.copied("https://example.com/unrelated")
        #expect(activity.summary == "Upload complete")
        activity.copied("https://example.com/test.png")
        #expect(activity.summary == "Link copied")
        let failure = UploadService(http: WorkflowHTTP(status: 403), credentials: UnusedCredentials(), activity: activity)
        do { _ = try await failure.upload(part: part, destination: destination); Issue.record("Expected failure") }
        catch {}
        #expect(activity.running.isEmpty)
        #expect(activity.summary == "Upload failed")
        #expect(activity.latest?.error?.contains("Access was denied") == true)
    }

    @Test func imgurDeletionUsesAPIAndClientID() async throws {
        let http = WorkflowHTTP(body: #"{"success":true,"data":true}"#)
        let destination = UploadDestination(id: "imgur", name: "Imgur", kind: .imgur, imgurClientID: "client")
        let model = UploaderTestModel(destination: destination, http: http) { _, _ in
            UploadResult(url: "https://i.imgur.com/example.png", deletionURL: "https://imgur.com/delete/DeleteHash123")
        }
        await model.run()
        await model.deleteTestUpload()
        #expect(model.deleted && model.error == nil)
        let request = try #require(await http.requests.first)
        #expect(request.method == .delete)
        #expect(request.url == "https://api.imgur.com/3/image/DeleteHash123")
        #expect(request.headers["Authorization"] == "Client-ID client")
    }

    @Test(arguments: [#"{"success":false,"data":true}"#, #"{"success":true,"data":false}"#,
                      "<html>Confirm deletion</html>"])
    func imgurDeletionMustBeConfirmed(body: String) async throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        var entry = fixture.entry(url: "https://i.imgur.com/example.png")
        entry.deletionURL = "https://imgur.com/delete/DeleteHash123"
        try fixture.store.insert(entry)
        let model = HistoryModel(store: fixture.store, http: WorkflowHTTP(body: body),
            settingsStore: fixture.settingsStore, effects: CaptureTestEffects())
        await model.deleteRemote(entry)
        #expect(model.deleteError != nil)
        #expect(try fixture.store.all(limit: 10).first == entry)
    }

    @Test func customDeletionPageDoesNotCountAsDeletion() async throws {
        let http = WorkflowHTTP(body: "<html>Confirm deletion</html>")
        let model = UploaderTestModel(destination: .init(id: "custom", name: "Custom", kind: .customUploader), http: http) { _, _ in
            UploadResult(url: "https://example.com/test.png", deletionURL: "https://example.com/delete/test")
        }
        await model.run()
        await model.deleteTestUpload()
        #expect(!model.deleted && model.error != nil)
        #expect(model.result?.deletionURL != nil)
    }

    @Test func concurrentActivityStaysUploadingUntilEveryOperationFinishes() {
        let activity = UploadActivity()
        let first = activity.begin(filename: "a.png", destination: "A")
        let second = activity.begin(filename: "b.png", destination: "B")
        #expect(activity.summary == "Uploading 2 files…")
        activity.finish(first, url: "https://example.com/a")
        #expect(activity.summary == "Uploading to B…")
        activity.finish(second, error: "Offline")
        #expect(activity.summary == "Upload failed")
    }

    @Test func filtersDistinguishVideosAndFailedImages() throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        var video = fixture.entry()
        video.filePath = fixture.directory.appendingPathComponent("recording.mp4").path
        video.uploadFailed = false
        #expect(HistoryFilter.images.includes(fixture.entry()))
        #expect(HistoryFilter.failed.includes(fixture.entry()))
        #expect(!HistoryFilter.images.includes(video))
        #expect(HistoryFilter.videos.includes(video))
        #expect(!HistoryFilter.failed.includes(video))
    }
}
