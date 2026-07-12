import Testing
import Foundation
@testable import SXCore

@Suite struct RecordingSettingsTests {
    @Test func defaultsMatchSpec() {
        let r = RecordingSettings.default
        #expect(r.systemAudio == false)
        #expect(r.videoCodec == .h264)
        #expect(r.gifFPS == 15)
        #expect(r.gifMaxWidth == 640)
    }

    @Test func settingsRoundTripPreservesRecording() throws {
        var s = AppSettings.default
        s.recording.systemAudio = true
        s.recording.videoCodec = .hevc
        s.recording.gifFPS = 24
        s.recording.gifMaxWidth = nil
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.recording.systemAudio == true)
        #expect(decoded.recording.videoCodec == .hevc)
        #expect(decoded.recording.gifFPS == 24)
        #expect(decoded.recording.gifMaxWidth == nil)
    }

    @Test func legacyFileWithoutRecordingKeyDefaultsIt() throws {
        // A settings JSON that predates the recording field (and the record
        // hotkey) must still decode — same v2-no-bump treatment as `editor`.
        // The record hotkey specifically must default to the shipped combo
        // (not nil), otherwise upgraded users silently lose the record
        // shortcut — see HotkeySettingsTests for dedicated coverage.
        let json = """
        {"schemaVersion":2,"captureSavePath":"~/Pictures/ShareX","filenameTemplate":"x",
         "saveToDisk":true,"copyToClipboard":true,"showNotification":true,
         "hotkeys":{"fullscreen":null,"region":null,"window":null}}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.recording == RecordingSettings.default)
        #expect(decoded.hotkeys.record == HotkeyCombo(keyCode: 22, modifiers: 2560))
    }

    @Test func defaultHotkeysIncludeRecord() {
        #expect(AppSettings.default.hotkeys.record == HotkeyCombo(keyCode: 22, modifiers: 2560))  // ⌥⇧6
    }
}
