import Testing
import Foundation
@testable import LumeshotCore

// Regression coverage for the upgrade bug: a pre-M4 `hotkeys` object (which
// only ever had fullscreen/region/window) decoded `record` to nil via
// synthesized Codable, so `AppDelegate.registerHotkeys`'s `if let combo =
// config.record` silently skipped registering the flagship ⌥⇧6 record
// shortcut for every existing user. `HotkeySettings.init(from:)` must default
// an absent `record` key to the shipped combo while leaving the other three
// keys' "absent → nil" semantics untouched.
@Suite struct HotkeySettingsTests {
    @Test func legacyHotkeysWithoutRecordKeyDefaultsToShippedCombo() throws {
        let json = """
        {"fullscreen":{"keyCode":20,"modifiers":2560},
         "region":{"keyCode":21,"modifiers":2560},
         "window":{"keyCode":23,"modifiers":2560}}
        """
        let decoded = try JSONDecoder().decode(HotkeySettings.self, from: Data(json.utf8))
        #expect(decoded.record == HotkeyCombo(keyCode: 22, modifiers: 2560))
        #expect(decoded.fullscreen == HotkeyCombo(keyCode: 20, modifiers: 2560))
        #expect(decoded.region == HotkeyCombo(keyCode: 21, modifiers: 2560))
        #expect(decoded.window == HotkeyCombo(keyCode: 23, modifiers: 2560))
    }

    @Test func presentRecordKeyIsPreservedNotOverriddenByDefault() throws {
        let json = """
        {"fullscreen":null,"region":null,"window":null,
         "record":{"keyCode":7,"modifiers":256}}
        """
        let decoded = try JSONDecoder().decode(HotkeySettings.self, from: Data(json.utf8))
        #expect(decoded.record == HotkeyCombo(keyCode: 7, modifiers: 256))
    }

    @Test func absentFullscreenStillDecodesToNil() throws {
        // The other three hotkeys keep today's "absent → nil" semantics —
        // only `record` gets a default-if-absent, since only it needs to
        // survive an upgrade from a settings file that predates the field.
        let json = """
        {"region":null,"window":null,"record":{"keyCode":22,"modifiers":2560}}
        """
        let decoded = try JSONDecoder().decode(HotkeySettings.self, from: Data(json.utf8))
        #expect(decoded.fullscreen == nil)
    }
}
