import Testing
import Foundation
@testable import LumeshotCore

@Suite struct RecordingCapabilityTests {
    private func dest(_ id: String, _ name: String, _ kind: UploadDestinationKind) -> UploadDestination {
        UploadDestination(id: id, name: name, kind: kind)
    }

    @Test func imageHostsDoNotAcceptRecordings() {
        #expect(!UploadDestinationKind.picsur.acceptsRecordings)
        #expect(!UploadDestinationKind.imgur.acceptsRecordings)
    }

    @Test func fileTransportsAcceptRecordings() {
        #expect(UploadDestinationKind.s3.acceptsRecordings)
        #expect(UploadDestinationKind.sftp.acceptsRecordings)
        #expect(UploadDestinationKind.ftp.acceptsRecordings)
    }

    /// A `.sxcu` uploader could be either, and guessing "no" would block a working
    /// configuration. Being wrong this way only costs the failure they'd have had.
    @Test func aCustomUploaderIsTreatedAsCapable() {
        #expect(UploadDestinationKind.customUploader.acceptsRecordings)
    }

    /// Every kind is classified — a new one must be a deliberate decision, not a
    /// default inherited from whichever branch it happens to fall into.
    @Test func everyKindIsClassified() {
        let kinds: [UploadDestinationKind] = [.customUploader, .imgur, .picsur, .s3, .sftp, .ftp]
        #expect(kinds.filter(\.acceptsRecordings).count == 4)
        #expect(kinds.filter { !$0.acceptsRecordings }.count == 2)
    }

    /// The exact state behind the bug report: a fresh install where recordings follow
    /// an image-only screenshot destination because none has been chosen yet.
    @Test func followingAnImageOnlyScreenshotDestinationIsFlagged() {
        let s = UploadSettings(uploadAfterCapture: true, activeDestinationID: "pic",
                               destinations: [dest("pic", "BSD", .picsur)])
        #expect(s.activeDestination(for: .recording)?.id == "pic")
        #expect(s.recordingDestinationRejectingVideo?.name == "BSD")
    }

    /// And the fix for it: pointing recordings at a transport that takes video.
    @Test func anExplicitCapableDestinationIsNotFlagged() {
        let s = UploadSettings(uploadAfterCapture: true, activeDestinationID: "pic",
                               activeRecordingDestinationID: "sftp",
                               destinations: [dest("pic", "BSD", .picsur),
                                              dest("sftp", "extfiles", .sftp)])
        #expect(s.recordingDestinationRejectingVideo == nil)
    }

    /// Explicitly choosing an image host for recordings is still flagged — the user
    /// can select it, but it will fail, and saying so beforehand beats a server error.
    @Test func anExplicitImageOnlyDestinationIsAlsoFlagged() {
        let s = UploadSettings(uploadAfterCapture: true, activeDestinationID: "sftp",
                               activeRecordingDestinationID: "pic",
                               destinations: [dest("pic", "BSD", .picsur),
                                              dest("sftp", "extfiles", .sftp)])
        #expect(s.recordingDestinationRejectingVideo?.name == "BSD")
    }

    @Test func nothingIsFlaggedWhenNoDestinationIsSelected() {
        let s = UploadSettings(uploadAfterCapture: false, activeDestinationID: nil,
                               destinations: [dest("pic", "BSD", .picsur)])
        #expect(s.recordingDestinationRejectingVideo == nil)
    }

    /// The message has to name the destination and point at the fix; a generic
    /// "unsupported" is what made the original failure read like a broken uploader.
    @Test func theMessageNamesTheDestinationAndTheRemedy() {
        let message = UploadFeedback.message(for: UploadError.destinationRejectsVideo(destination: "BSD"))
        #expect(message.contains("BSD"))
        #expect(message.contains("Screen recordings"))
        #expect(!message.contains("isn’t supported"))   // not the generic branch
    }
}
