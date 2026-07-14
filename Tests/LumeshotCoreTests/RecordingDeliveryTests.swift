import Foundation
import Testing
@testable import LumeshotCore

private func tempHistoryStore() throws -> HistoryStore {
    try HistoryStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("history.sqlite"))
}

private func tempFile(bytes: [UInt8] = [0, 1, 2, 3]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    try Data(bytes).write(to: url)   // stand-in bytes; delivery treats the file as opaque
    return url
}

private struct Boom: Error {}

@MainActor @Suite struct RecordingDeliveryTests {
    @Test func insertsHistoryRowBeforeInvokingTheUploadClosure() async throws {
        let fileURL = try tempFile()
        let history = try tempHistoryStore()
        let effects = MockEffects()
        var rowPresentWhenUploadRan = false
        await RecordingDelivery.deliver(
            fileURL: fileURL, capturedAt: Date(), destinationName: "Imgur",
            shouldUpload: true, showNotification: true, mime: "video/mp4",
            history: history, effects: effects,
            upload: { _, _, _ in
                // The upload runs AFTER the row is inserted (local-first ordering).
                rowPresentWhenUploadRan = ((try? history.recent(limit: 1))?.isEmpty == false)
                return DeliveredUpload(url: "https://i/x.mp4", deletionURL: "https://i/del")
            })
        #expect(rowPresentWhenUploadRan)
    }

    @Test func successUpdatesRowCopiesUrlAndNotifiesWithoutReencoding() async throws {
        let fileURL = try tempFile()
        let history = try tempHistoryStore()
        let effects = MockEffects()
        await RecordingDelivery.deliver(
            fileURL: fileURL, capturedAt: Date(), destinationName: "Imgur",
            shouldUpload: true, showNotification: true, mime: "video/mp4",
            history: history, effects: effects,
            upload: { _, _, _ in DeliveredUpload(url: "https://i/x.mp4", deletionURL: "https://i/del") })
        let rows = try history.recent(limit: 1)
        #expect(rows.first?.url == "https://i/x.mp4")
        #expect(rows.first?.deletionURL == "https://i/del")
        #expect(rows.first?.uploadFailed == false)
        #expect(effects.textCopies == ["https://i/x.mp4"])
        #expect(effects.callOrder.contains("copyText"))
        #expect(effects.callOrder.contains("notifyURL"))
        #expect(!effects.callOrder.contains("write"))   // no re-encode; SCRecordingOutput already wrote the file
    }

    @Test func failureKeepsRowWithUploadFailedAndNeverTouchesTheFile() async throws {
        let fileURL = try tempFile()
        let before = try Data(contentsOf: fileURL)
        let history = try tempHistoryStore()
        let effects = MockEffects()
        await RecordingDelivery.deliver(
            fileURL: fileURL, capturedAt: Date(), destinationName: "Imgur",
            shouldUpload: true, showNotification: true, mime: "video/mp4",
            history: history, effects: effects,
            upload: { _, _, _ in throw Boom() })
        let rows = try history.recent(limit: 1)
        #expect(rows.first?.filePath == fileURL.path)     // row remains
        #expect(rows.first?.uploadFailed == true)
        #expect(rows.first?.url == nil)
        #expect(effects.notifications.contains { $0.0.contains("Local file kept") })   // fail-loud
        #expect(FileManager.default.fileExists(atPath: fileURL.path))   // local-first: file untouched
        #expect(try Data(contentsOf: fileURL) == before)
    }

    @Test func noUploadNotifiesRecordingSavedAndSkipsTheUploadClosure() async throws {
        let fileURL = try tempFile()
        let history = try tempHistoryStore()
        let effects = MockEffects()
        var uploadRan = false
        await RecordingDelivery.deliver(
            fileURL: fileURL, capturedAt: Date(), destinationName: nil,
            shouldUpload: false, showNotification: true, mime: "video/mp4",
            history: history, effects: effects,
            upload: { _, _, _ in uploadRan = true; return DeliveredUpload(url: "x", deletionURL: nil) })
        #expect(!uploadRan)
        #expect(effects.callOrder == ["notify"])
        #expect(effects.notifications.first?.0 == fileURL.lastPathComponent)
        let rows = try history.recent(limit: 1)
        #expect(rows.first?.filePath == fileURL.path)
        #expect(rows.first?.url == nil)
        #expect(rows.first?.uploadFailed == false)
    }
}
