import Foundation

public struct HotkeyCombo: Codable, Equatable, Sendable {
    public var keyCode: UInt32     // Carbon virtual key code
    public var modifiers: UInt32   // Carbon modifier mask
    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct HotkeySettings: Codable, Equatable, Sendable {
    public var fullscreen: HotkeyCombo?
    public var region: HotkeyCombo?
    public var window: HotkeyCombo?
    public init(fullscreen: HotkeyCombo?, region: HotkeyCombo?, window: HotkeyCombo?) {
        self.fullscreen = fullscreen
        self.region = region
        self.window = window
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var captureSavePath: String     // supports leading ~
    public var filenameTemplate: String    // NameParser template, no extension
    public var saveToDisk: Bool
    public var copyToClipboard: Bool
    public var showNotification: Bool
    public var hotkeys: HotkeySettings

    // Carbon: optionKey(2048) | shiftKey(512) = 2560; kVK_ANSI_3=20, _4=21, _5=23
    public static let `default` = AppSettings(
        schemaVersion: 1,
        captureSavePath: "~/Pictures/ShareX",
        filenameTemplate: "Screenshot_%y-%mo-%d_%h-%mi-%s",
        saveToDisk: true,
        copyToClipboard: true,
        showNotification: true,
        hotkeys: HotkeySettings(
            fullscreen: HotkeyCombo(keyCode: 20, modifiers: 2560),
            region: HotkeyCombo(keyCode: 21, modifiers: 2560),
            window: HotkeyCombo(keyCode: 23, modifiers: 2560)
        )
    )
}
