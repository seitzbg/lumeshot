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

public struct EditorSettings: Codable, Equatable, Sendable {
    public var annotateBeforeShare: Bool
    public init(annotateBeforeShare: Bool) {
        self.annotateBeforeShare = annotateBeforeShare
    }
    public static let `default` = EditorSettings(annotateBeforeShare: false)
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var captureSavePath: String     // supports leading ~
    public var filenameTemplate: String    // NameParser template, no extension
    public var saveToDisk: Bool
    public var copyToClipboard: Bool
    public var showNotification: Bool
    public var hotkeys: HotkeySettings
    public var upload: UploadSettings
    public var editor: EditorSettings

    public init(schemaVersion: Int, captureSavePath: String, filenameTemplate: String,
                saveToDisk: Bool, copyToClipboard: Bool, showNotification: Bool,
                hotkeys: HotkeySettings, upload: UploadSettings,
                editor: EditorSettings = .default) {
        self.schemaVersion = schemaVersion
        self.captureSavePath = captureSavePath
        self.filenameTemplate = filenameTemplate
        self.saveToDisk = saveToDisk
        self.copyToClipboard = copyToClipboard
        self.showNotification = showNotification
        self.hotkeys = hotkeys
        self.upload = upload
        self.editor = editor
    }

    // Tolerate a v1 file with no `upload` or `editor` key by defaulting them (migration in
    // SettingsStore bumps the version); every other field is required as before.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        captureSavePath = try c.decode(String.self, forKey: .captureSavePath)
        filenameTemplate = try c.decode(String.self, forKey: .filenameTemplate)
        saveToDisk = try c.decode(Bool.self, forKey: .saveToDisk)
        copyToClipboard = try c.decode(Bool.self, forKey: .copyToClipboard)
        showNotification = try c.decode(Bool.self, forKey: .showNotification)
        hotkeys = try c.decode(HotkeySettings.self, forKey: .hotkeys)
        upload = try c.decodeIfPresent(UploadSettings.self, forKey: .upload) ?? .disabled
        editor = try c.decodeIfPresent(EditorSettings.self, forKey: .editor) ?? .default
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, captureSavePath, filenameTemplate, saveToDisk,
             copyToClipboard, showNotification, hotkeys, upload, editor
    }

    // Carbon: optionKey(2048) | shiftKey(512) = 2560; kVK_ANSI_3=20, _4=21, _5=23
    public static let `default` = AppSettings(
        schemaVersion: 2,
        captureSavePath: "~/Pictures/ShareX",
        filenameTemplate: "Screenshot_%y-%mo-%d_%h-%mi-%s",
        saveToDisk: true,
        copyToClipboard: true,
        showNotification: true,
        hotkeys: HotkeySettings(
            fullscreen: HotkeyCombo(keyCode: 20, modifiers: 2560),
            region: HotkeyCombo(keyCode: 21, modifiers: 2560),
            window: HotkeyCombo(keyCode: 23, modifiers: 2560)
        ),
        upload: .disabled,
        editor: .default
    )
}
