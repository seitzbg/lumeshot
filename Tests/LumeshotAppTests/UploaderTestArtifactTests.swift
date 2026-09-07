import Testing
import Foundation
import AVFoundation
@testable import LumeshotApp
@testable import LumeshotCore

@MainActor
@Suite struct UploaderTestArtifactTests {
    private func dest(_ kind: UploadDestinationKind) -> UploadDestination {
        UploadDestination(id: "d", name: "D", kind: kind)
    }

    /// The generated clip has to be a real, playable mp4 — an empty or truncated file
    /// would "pass" the upload and prove nothing about the destination.
    @Test func theSampleVideoIsAPlayableMP4() async throws {
        let part = try await UploaderTestModel.sampleVideo()
        #expect(part.mimeType == "video/mp4")
        #expect(part.filename.hasSuffix(".mp4"))

        guard case .data(let bytes) = part.source else {
            Issue.record("expected in-memory data, got \(part.source)"); return
        }
        #expect(bytes.count > 500)

        // Round-trip through AVFoundation: if it cannot be opened and timed, it is
        // not a video, whatever the extension says.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString).mp4")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 0)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
    }

    @Test func videoCapableDestinationsAreTestedWithVideo() async throws {
        for kind in [UploadDestinationKind.s3, .sftp, .ftp, .customUploader] {
            let part = try await UploaderTestModel.sampleArtifact(for: dest(kind))
            #expect(part.mimeType == "video/mp4", "\(kind) should be tested with video")
        }
    }

    /// Sending a clip to an image host only proves it says no, so those keep the image.
    @Test func imageOnlyDestinationsAreTestedWithAnImage() async throws {
        for kind in [UploadDestinationKind.picsur, .imgur] {
            let part = try await UploaderTestModel.sampleArtifact(for: dest(kind))
            #expect(part.mimeType == "image/png", "\(kind) should be tested with an image")
        }
    }

    @Test func theSheetSaysWhichArtifactItWillSend() {
        let video = UploaderTestModel(destination: dest(.sftp)) { _, _ in
            UploadResult(url: "u", deletionURL: nil)
        }
        let image = UploaderTestModel(destination: dest(.picsur)) { _, _ in
            UploadResult(url: "u", deletionURL: nil)
        }
        #expect(video.artifactDescription.contains("video"))
        #expect(image.artifactDescription.contains("image"))
    }
}
