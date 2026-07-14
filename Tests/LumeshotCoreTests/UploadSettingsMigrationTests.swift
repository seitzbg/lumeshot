import Foundation
import Testing
@testable import LumeshotCore

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json")
}

@Suite struct UploadSettingsMigrationTests {
    @Test func defaultsIncludeDisabledUploadAtSchema2() {
        #expect(AppSettings.default.schemaVersion == 2)
        #expect(AppSettings.default.upload == UploadSettings.disabled)
        #expect(AppSettings.default.upload.uploadAfterCapture == false)
    }

    @Test func migratesV1FileWithoutUploadKey() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // A settings.json written by M1 (schemaVersion 1, no `upload`).
        let v1 = """
        {"schemaVersion":1,"captureSavePath":"~/Pictures/ShareX",
         "filenameTemplate":"Screenshot_%y","saveToDisk":true,"copyToClipboard":true,
         "showNotification":true,
         "hotkeys":{"fullscreen":{"keyCode":20,"modifiers":2560},
                    "region":{"keyCode":21,"modifiers":2560},
                    "window":{"keyCode":23,"modifiers":2560}}}
        """
        try Data(v1.utf8).write(to: url)
        let (settings, issue) = SettingsStore(fileURL: url).loadOrDefault()
        #expect(issue == nil)                              // migration is not an error
        #expect(settings.schemaVersion == 2)
        #expect(settings.captureSavePath == "~/Pictures/ShareX")   // preserved
        #expect(settings.upload == UploadSettings.disabled)        // injected
    }

    @Test func roundTripsDestinations() throws {
        let url = tempFile()
        let store = SettingsStore(fileURL: url)
        var s = AppSettings.default
        var config = CustomUploaderConfig(requestURL: "https://up")
        config.fileFormName = "file"
        s.upload.destinations = [UploadDestination(id: "d1", name: "Mine",
                                                   kind: .customUploader,
                                                   customUploader: config, imgurClientID: nil)]
        s.upload.activeDestinationID = "d1"
        s.upload.uploadAfterCapture = true
        try store.save(s)
        let (loaded, _) = store.loadOrDefault()
        #expect(loaded.upload.activeDestinationID == "d1")
        #expect(loaded.upload.destinations.first?.customUploader?.requestURL == "https://up")
    }

    @Test func legacyDestinationJSONWithoutSFTPFTPFieldsDecodes() throws {
        // A destination JSON written before M5a (no sftpConfig/ftpConfig keys).
        let json = """
        {"id":"d1","name":"My S3","kind":"s3",
         "s3Config":{"region":"us-east-1","endpoint":"s3.amazonaws.com","bucket":"b",
                     "objectPrefix":"","addressingStyle":"VirtualHost"}}
        """
        let decoded = try JSONDecoder().decode(UploadDestination.self, from: Data(json.utf8))
        #expect(decoded.sftpConfig == nil)
        #expect(decoded.ftpConfig == nil)
        #expect(decoded.s3Config?.bucket == "b")   // pre-existing fields unaffected
    }
}
