import Foundation
import Testing
@testable import LumeshotCore

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("settings.json")
}

@Suite struct SettingsStoreTests {
    @Test func missingFileYieldsDefaultsWithoutIssue() {
        let store = SettingsStore(fileURL: tempFile())
        let (settings, issue) = store.loadOrDefault()
        #expect(settings == AppSettings.default)
        #expect(issue == nil)
    }

    @Test func roundTripPreservesValues() throws {
        let url = tempFile()
        let store = SettingsStore(fileURL: url)
        var s = AppSettings.default
        s.filenameTemplate = "shot_%y"
        s.hotkeys.region = HotkeyCombo(keyCode: 99, modifiers: 2560)
        try store.save(s)
        let (loaded, issue) = store.loadOrDefault()
        #expect(loaded == s)
        #expect(issue == nil)
    }

    @Test func corruptFileBacksUpAndReturnsDefaults() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = SettingsStore(fileURL: url)
        let (settings, issue) = store.loadOrDefault()
        #expect(settings == AppSettings.default)
        guard case .corruptBackedUp(let backupURL)? = issue else {
            Issue.record("expected corruptBackedUp issue"); return
        }
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func unreadableFileYieldsDefaultsWithReadFailedIssue() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let store = SettingsStore(fileURL: url)
        try store.save(.default)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }

        let (settings, issue) = store.loadOrDefault()

        #expect(settings == AppSettings.default)
        guard case .readFailed? = issue else {
            Issue.record("expected readFailed issue"); return
        }
    }

    /// A settings file that exists but cannot be read must not be mistaken for an
    /// empty configuration. `mutate` treated `loadOrDefault`'s fallback as an
    /// authoritative snapshot, so a change would write the defaults over the
    /// (recoverable) file and erase every destination, filename template and
    /// pinned host key. The transaction has to abort instead, leaving the file
    /// byte-for-byte intact.
    @Test func mutateOnUnreadableFileThrowsAndLeavesItUntouched() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let store = SettingsStore(fileURL: url)
        var saved = AppSettings.default
        saved.filenameTemplate = "KEEP_ME"
        saved.upload = saved.upload.addingOrUpdating(
            UploadDestination(id: "d1", name: "D1", kind: .imgur, imgurClientID: "client"))
        try store.save(saved)
        let before = try Data(contentsOf: url)

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        #expect(throws: (any Error).self) {
            try store.mutate { $0.filenameTemplate = "OVERWRITTEN" }
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == before)   // destinations + template preserved
    }

    @Test func defaultsHaveExpectedHotkeys() {
        let d = AppSettings.default
        #expect(d.hotkeys.fullscreen == HotkeyCombo(keyCode: 20, modifiers: 2560)) // ⌥⇧3
        #expect(d.hotkeys.region == HotkeyCombo(keyCode: 21, modifiers: 2560))     // ⌥⇧4
        #expect(d.hotkeys.window == HotkeyCombo(keyCode: 23, modifiers: 2560))     // ⌥⇧5
        #expect(d.schemaVersion == 2)
    }

    /// Atomic file writes stop a reader seeing half a document; they do nothing
    /// for two writers. The SSH host-key callback runs a load/modify/save from a
    /// background thread while the main actor saves a settings edit, and
    /// separate load and save calls let those interleave and drop one update.
    @Test func concurrentTransactionsDoNotLoseUpdates() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(fileURL: dir.appendingPathComponent("settings.json"))
        try store.save(.default)

        // Each task adds one destination. Every one must survive.
        let count = 24
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    try? store.mutate { settings in
                        settings.upload = settings.upload.addingOrUpdating(
                            UploadDestination(id: "dest-\(i)", name: "D\(i)", kind: .imgur,
                                              imgurClientID: "client"))
                    }
                }
            }
        }
        #expect(store.loadOrDefault().0.upload.destinations.count == count)
    }
}
