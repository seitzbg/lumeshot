import Foundation

/// Pure (no AppKit/Carbon import) conversion between the Carbon modifier mask
/// stored in HotkeyCombo.modifiers and the raw bit layout of AppKit's
/// NSEvent.ModifierFlags, so this file has no platform-framework dependency
/// and Tests/LumeshotCoreTests can exercise it without a live NSEvent.
///
/// Carbon masks (Events.h): cmdKey=256, shiftKey=512, optionKey=2048, controlKey=4096.
/// AppKit raw bits (NSEvent.h): shift=1<<17, control=1<<18, option=1<<19, command=1<<20.
public enum HotkeyModifiers {
    public static let carbonCommand: UInt32 = 256
    public static let carbonShift: UInt32 = 512
    public static let carbonOption: UInt32 = 2048
    public static let carbonControl: UInt32 = 4096

    public static let appKitShift: UInt = 1 << 17
    public static let appKitControl: UInt = 1 << 18
    public static let appKitOption: UInt = 1 << 19
    public static let appKitCommand: UInt = 1 << 20

    /// `raw` is expected to already be masked to NSEvent's device-independent
    /// modifier bits (the caller intersects with `.deviceIndependentFlagsMask`
    /// before passing it in) — this function only inspects the 4 bits above.
    public static func carbonMask(fromAppKit raw: UInt) -> UInt32 {
        var mask: UInt32 = 0
        if raw & appKitControl != 0 { mask |= carbonControl }
        if raw & appKitOption  != 0 { mask |= carbonOption }
        if raw & appKitShift   != 0 { mask |= carbonShift }
        if raw & appKitCommand != 0 { mask |= carbonCommand }
        return mask
    }

    public static func appKitRaw(fromCarbon mask: UInt32) -> UInt {
        var raw: UInt = 0
        if mask & carbonControl != 0 { raw |= appKitControl }
        if mask & carbonOption  != 0 { raw |= appKitOption }
        if mask & carbonShift   != 0 { raw |= appKitShift }
        if mask & carbonCommand != 0 { raw |= appKitCommand }
        return raw
    }
}

public extension HotkeyCombo {
    /// Carbon virtual-keycode -> human label for the keys a global hotkey can
    /// reasonably use: letters, digits, common punctuation, arrows, space,
    /// and a handful of editing/navigation keys. Unlisted keycodes fall back
    /// to "Key<N>" rather than silently rendering nothing.
    private static let keyLabels: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 36: "\u{21A9}",   // Return
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "\u{21E5}",   // Tab
        49: "Space", 50: "`", 51: "\u{232B}",         // Delete (backspace)
        53: "\u{238B}",                                // Escape
        115: "Home", 116: "Page Up", 117: "\u{2326}",  // Forward Delete
        119: "End", 121: "Page Down",
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
    ]

    /// Canonical macOS modifier glyph order: Control, Option, Shift, Command.
    var displayString: String {
        var s = ""
        if modifiers & HotkeyModifiers.carbonControl != 0 { s += "\u{2303}" }
        if modifiers & HotkeyModifiers.carbonOption  != 0 { s += "\u{2325}" }
        if modifiers & HotkeyModifiers.carbonShift   != 0 { s += "\u{21E7}" }
        if modifiers & HotkeyModifiers.carbonCommand != 0 { s += "\u{2318}" }
        s += Self.keyLabels[keyCode] ?? "Key\(keyCode)"
        return s
    }
}
