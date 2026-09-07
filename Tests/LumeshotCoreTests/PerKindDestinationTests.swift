import Testing
import Foundation
@testable import LumeshotCore

@Suite struct PerKindDestinationTests {
    private func dest(_ id: String, _ name: String) -> UploadDestination {
        UploadDestination(id: id, name: name, kind: .picsur)
    }

    private func settings(active: String?, recording: String? = nil) -> UploadSettings {
        UploadSettings(uploadAfterCapture: true, activeDestinationID: active,
                       activeRecordingDestinationID: recording,
                       destinations: [dest("pic", "Picsur"), dest("s3", "S3")])
    }

    @Test func recordingsFollowImagesWhenUnset() {
        let s = settings(active: "pic")
        #expect(s.activeDestination(for: .image)?.id == "pic")
        #expect(s.activeDestination(for: .recording)?.id == "pic")
        #expect(!s.usesSeparateRecordingDestination)
    }

    /// The point of the feature: Picsur takes the screenshots, S3 takes the video.
    @Test func recordingsCanTargetTheirOwnDestination() {
        let s = settings(active: "pic", recording: "s3")
        #expect(s.activeDestination(for: .image)?.id == "pic")
        #expect(s.activeDestination(for: .recording)?.id == "s3")
        #expect(s.usesSeparateRecordingDestination)
    }

    /// A recording destination that no longer resolves must not silently fall back to
    /// the image host — that is the bug this feature exists to prevent.
    @Test func aDanglingRecordingIDUploadsNowhereRatherThanToImages() {
        let s = UploadSettings(uploadAfterCapture: true, activeDestinationID: "pic",
                               activeRecordingDestinationID: "deleted",
                               destinations: [dest("pic", "Picsur")])
        #expect(s.activeDestination(for: .image)?.id == "pic")
        #expect(s.activeDestination(for: .recording) == nil)
    }

    @Test func removingTheRecordingDestinationRevertsToFollowingImages() {
        let s = settings(active: "pic", recording: "s3").removing(id: "s3")
        #expect(s.activeRecordingDestinationID == nil)
        #expect(s.activeDestination(for: .recording)?.id == "pic")
    }

    @Test func removingTheImageDestinationLeavesAnExplicitRecordingChoiceAlone() {
        let s = settings(active: "pic", recording: "s3").removing(id: "pic")
        #expect(s.activeDestination(for: .image) == nil)
        #expect(s.activeDestination(for: .recording)?.id == "s3")
        #expect(!s.uploadAfterCapture)   // no image destination disables automation
    }

    @Test func settingActiveRecordingRejectsAnUnknownID() {
        let s = settings(active: "pic").settingActiveRecording(id: "nope")
        #expect(s.activeRecordingDestinationID == nil)
    }

    @Test func settingActiveRecordingToNilFollowsImagesAgain() {
        let s = settings(active: "pic", recording: "s3").settingActiveRecording(id: nil)
        #expect(s.activeDestination(for: .recording)?.id == "pic")
    }

    /// Every settings file written before this field existed must keep working and
    /// must behave exactly as it did — recordings following the image destination.
    @Test func settingsWrittenBeforeThisFieldExistedStillDecode() throws {
        let legacy = Data("""
        {"uploadAfterCapture":true,"activeDestinationID":"pic",
         "destinations":[{"id":"pic","name":"Picsur","kind":"picsur"}]}
        """.utf8)
        let decoded = try JSONDecoder().decode(UploadSettings.self, from: legacy)
        #expect(decoded.activeRecordingDestinationID == nil)
        #expect(decoded.activeDestination(for: .recording)?.id == "pic")
        #expect(decoded.activeDestination(for: .image)?.id == "pic")
    }

    /// And a whole AppSettings file, since that is what SettingsStore actually reads.
    @Test func aLegacyAppSettingsFileStillDecodes() throws {
        let legacy = Data("""
        {"schemaVersion":2,"captureSavePath":"~/Pictures/Lumeshot",
         "filenameTemplate":"Screenshot_%y","saveToDisk":true,"showNotification":true,
         "hotkeys":{},
         "upload":{"uploadAfterCapture":true,"activeDestinationID":"pic",
                   "destinations":[{"id":"pic","name":"Picsur","kind":"picsur"}]}}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        #expect(decoded.upload.activeDestination(for: .recording)?.id == "pic")
    }

    @Test func roundTripsThroughJSON() throws {
        let original = settings(active: "pic", recording: "s3")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UploadSettings.self, from: data)
        #expect(decoded == original)
        #expect(decoded.activeDestination(for: .recording)?.id == "s3")
    }
}
