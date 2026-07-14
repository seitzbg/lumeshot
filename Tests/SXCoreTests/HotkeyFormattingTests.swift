import Testing
import Foundation
@testable import SXCore

@Suite struct HotkeyFormattingTests {
    // Default combos, verified live against AppSettings.default.
    @Test func fullscreenComboRendersAsOptionShift3() {
        #expect(HotkeyCombo(keyCode: 20, modifiers: 2560).displayString == "\u{2325}\u{21E7}3")
    }

    @Test func regionComboRendersAsOptionShift4() {
        #expect(HotkeyCombo(keyCode: 21, modifiers: 2560).displayString == "\u{2325}\u{21E7}4")
    }

    @Test func windowComboRendersAsOptionShift5() {
        #expect(HotkeyCombo(keyCode: 23, modifiers: 2560).displayString == "\u{2325}\u{21E7}5")
    }

    @Test func recordComboRendersAsOptionShift6() {
        #expect(HotkeyCombo(keyCode: 22, modifiers: 2560).displayString == "\u{2325}\u{21E7}6")
    }

    @Test func defaultAppSettingsHotkeysMatchTheirExpectedDisplayStrings() {
        let hotkeys = AppSettings.default.hotkeys
        #expect(hotkeys.fullscreen?.displayString == "\u{2325}\u{21E7}3")
        #expect(hotkeys.region?.displayString == "\u{2325}\u{21E7}4")
        #expect(hotkeys.window?.displayString == "\u{2325}\u{21E7}5")
        #expect(hotkeys.record?.displayString == "\u{2325}\u{21E7}6")
    }

    @Test func allFourModifiersRenderInCanonicalControlOptionShiftCommandOrder() {
        let mask = HotkeyModifiers.carbonControl | HotkeyModifiers.carbonOption
            | HotkeyModifiers.carbonShift | HotkeyModifiers.carbonCommand
        #expect(HotkeyCombo(keyCode: 49, modifiers: mask).displayString
                == "\u{2303}\u{2325}\u{21E7}\u{2318}Space")
    }

    @Test func modifierMaskRoundTripsFromAppKitToCarbonAndBack() {
        let appKitRaw = HotkeyModifiers.appKitControl | HotkeyModifiers.appKitShift
        let carbon = HotkeyModifiers.carbonMask(fromAppKit: appKitRaw)
        #expect(carbon == HotkeyModifiers.carbonControl | HotkeyModifiers.carbonShift)
        #expect(HotkeyModifiers.appKitRaw(fromCarbon: carbon) == appKitRaw)
    }

    @Test func modifierMaskRoundTripsAllFourBitsIndependently() {
        for carbonBit in [HotkeyModifiers.carbonControl, HotkeyModifiers.carbonOption,
                          HotkeyModifiers.carbonShift, HotkeyModifiers.carbonCommand] {
            let appKit = HotkeyModifiers.appKitRaw(fromCarbon: carbonBit)
            #expect(HotkeyModifiers.carbonMask(fromAppKit: appKit) == carbonBit)
        }
    }

    @Test func unknownKeyCodeFallsBackToKeyPlusCode() {
        #expect(HotkeyCombo(keyCode: 9999, modifiers: 0).displayString == "Key9999")
    }

    @Test func noModifiersRendersJustTheKeyLabel() {
        #expect(HotkeyCombo(keyCode: 0, modifiers: 0).displayString == "A")
    }
}
