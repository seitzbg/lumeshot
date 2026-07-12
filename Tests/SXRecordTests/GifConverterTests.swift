import Foundation
import Testing
@testable import SXRecord

@Suite struct GifConverterFrameTimesTests {
    @Test func evenlySpacedSamplesAtTheRequestedFPS() {
        let times = GifConverter.frameTimes(duration: 2.0, fps: 15)
        #expect(times.count == 30)
        #expect(times.first == 0.0)
        #expect(times == times.sorted())              // monotonic
        #expect(times.allSatisfy { $0 < 2.0 })         // never reaches/exceeds duration
    }

    @Test func zeroDurationYieldsASingleFrameAtZero() {
        #expect(GifConverter.frameTimes(duration: 0, fps: 15) == [0])
    }

    @Test func zeroFPSYieldsASingleFrameAtZero() {
        #expect(GifConverter.frameTimes(duration: 5, fps: 0) == [0])
    }

    @Test func negativeDurationYieldsASingleFrameAtZero() {
        #expect(GifConverter.frameTimes(duration: -1, fps: 15) == [0])
    }

    @Test func lowFPSStillProducesAtLeastOneFrame() {
        let times = GifConverter.frameTimes(duration: 0.1, fps: 1)
        #expect(times.count >= 1)
        #expect(times.first == 0.0)
    }
}

import AVFoundation
import ImageIO
import CoreVideo

@Suite struct GifConverterLiveTests {
    /// Writes a 1-second, 4x4, alternating-color H.264 mp4 via AVAssetWriter —
    /// enough signal for AVAssetImageGenerator to sample frames from, without
    /// needing ScreenCaptureKit or the Screen Recording TCC grant. This test
    /// therefore runs unconditionally (no `.enabled(if:)` gate) — it is not an
    /// SCK live test, just plain AVFoundation, so CI gets real GIF-pixel coverage.
    private func makeTinyMP4() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 4,
            AVVideoHeightKey: 4,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<8 {
            var pixelBuffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else { break }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let buffer = pixelBuffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, frame % 2 == 0 ? 0 : 255, CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 8))
        }
        input.markAsFinished()
        await writer.finishWriting()   // VERIFY on Mac: async finishWriting() overload requires macOS 15+ (matches our floor).
        return url
    }

    @Test func convertsAShortClipToANonEmptyAnimatedGIF() async throws {
        let mp4 = try await makeTinyMP4()
        defer { try? FileManager.default.removeItem(at: mp4) }
        let gifURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
        defer { try? FileManager.default.removeItem(at: gifURL) }

        try await GifConverter.convert(videoURL: mp4, to: gifURL,
                                       options: .init(fps: 4, maxWidth: nil))

        #expect(FileManager.default.fileExists(atPath: gifURL.path))
        let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil)
        #expect(source != nil)
        if let source { #expect(CGImageSourceGetCount(source) > 1) }
    }
}
