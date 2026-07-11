import Foundation
import Testing
@testable import SXCore

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
        s.copyToClipboard = false
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

    @Test func defaultsHaveExpectedHotkeys() {
        let d = AppSettings.default
        #expect(d.hotkeys.fullscreen == HotkeyCombo(keyCode: 20, modifiers: 2560)) // ⌥⇧3
        #expect(d.hotkeys.region == HotkeyCombo(keyCode: 21, modifiers: 2560))     // ⌥⇧4
        #expect(d.hotkeys.window == HotkeyCombo(keyCode: 23, modifiers: 2560))     // ⌥⇧5
        #expect(d.schemaVersion == 2)
    }
}
