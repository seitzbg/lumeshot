import Foundation
import Testing
@testable import LumeshotCore

@Suite struct HotkeySettingsCodingTests {
    private let shippedRecord = HotkeyCombo(keyCode: 22, modifiers: 2560)

    private func decode(_ json: String) throws -> HotkeySettings {
        try JSONDecoder().decode(HotkeySettings.self, from: Data(json.utf8))
    }

    @Test func absentRecordKeyMigratesToTheShippedDefault() throws {
        // Pre-M4 settings.json: no `record` key at all.
        let s = try decode(#"{"fullscreen":{"keyCode":1,"modifiers":2}}"#)
        #expect(s.record == shippedRecord)
    }

    @Test func explicitNullRecordMeansTheUserClearedIt() throws {
        let s = try decode(#"{"record":null}"#)
        #expect(s.record == nil)
    }

    @Test func clearedRecordSurvivesASaveReloadRoundTrip() throws {
        var settings = HotkeySettings(fullscreen: nil, region: nil, window: nil,
                                      record: shippedRecord)
        settings.record = nil   // what the Preferences clear button does
        let data = try JSONEncoder().encode(settings)
        // The key must be present-and-null, not omitted, or the decoder's
        // legacy-migration branch restores the default.
        #expect(String(decoding: data, as: UTF8.self).contains("\"record\":null"))
        #expect(try JSONDecoder().decode(HotkeySettings.self, from: data).record == nil)
    }

    @Test func aSetRecordRoundTrips() throws {
        let settings = HotkeySettings(fullscreen: nil, region: nil, window: nil,
                                      record: HotkeyCombo(keyCode: 9, modifiers: 4))
        let decoded = try JSONDecoder().decode(HotkeySettings.self,
                                               from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test func clearingTheOtherThreeStillMeansNil() throws {
        let s = try decode(#"{"record":null}"#)
        #expect(s.fullscreen == nil && s.region == nil && s.window == nil)
    }
}
