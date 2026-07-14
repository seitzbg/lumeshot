import Testing
import Foundation
@testable import LumeshotCore

@Suite struct EditorSettingsTests {
    @Test func defaultDisablesAnnotateBeforeShare() {
        #expect(AppSettings.default.editor.annotateBeforeShare == false)
    }

    @Test func settingsRoundTripPreservesEditor() throws {
        var s = AppSettings.default
        s.editor.annotateBeforeShare = true
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.editor.annotateBeforeShare == true)
    }

    @Test func legacyFileWithoutEditorKeyDefaultsIt() throws {
        // A settings JSON that predates the editor field must still decode.
        let json = """
        {"schemaVersion":2,"captureSavePath":"~/Pictures/ShareX","filenameTemplate":"x",
         "saveToDisk":true,"copyToClipboard":true,"showNotification":true,
         "hotkeys":{"fullscreen":null,"region":null,"window":null}}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.editor.annotateBeforeShare == false)
    }
}
