import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Native mp4/mov -> animated GIF conversion. No external dependency; the
/// optional higher-quality ffmpeg path (Task 15) is never required — this is
/// always the fallback and the only path CI exercises.
public enum GifConverter {
    public struct Options: Sendable {
        public let fps: Int
        public let maxWidth: Int?   // px; nil = source width
        public init(fps: Int, maxWidth: Int?) { self.fps = fps; self.maxWidth = maxWidth }
    }

    /// Pure, testable: evenly-spaced sample times (seconds) for `duration` at `fps` (>=1 frame).
    public static func frameTimes(duration: Double, fps: Int) -> [Double] {
        guard duration > 0, fps > 0 else { return [0] }
        let count = max(1, Int((duration * Double(fps)).rounded(.down)))
        let step = duration / Double(count)
        return (0..<count).map { Double($0) * step }
    }

    /// Convert an mp4/mov to an animated GIF (loop forever) via AVAssetImageGenerator -> CGImageDestination.
    public static func convert(videoURL: URL, to gifURL: URL, options: Options) async throws {
        let asset = AVURLAsset(url: videoURL)
        let seconds = try await asset.load(.duration).seconds
        let duration = seconds.isFinite && seconds > 0 ? seconds : 0

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let maxWidth = options.maxWidth {
            generator.maximumSize = CGSize(width: maxWidth, height: 0)   // 0 = keep aspect
        }

        let times = frameTimes(duration: duration, fps: options.fps)
            .map { CMTime(seconds: $0, preferredTimescale: 600) }

        guard let destination = CGImageDestinationCreateWithURL(
            gifURL as CFURL, UTType.gif.identifier as CFString, times.count, nil)
        else { throw RecordingError.conversionFailed("Could not create GIF destination at \(gifURL.path)") }

        let gifProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(destination, gifProperties)

        let frameDelay = 1.0 / Double(options.fps > 0 ? options.fps : 15)
        let frameProperties = [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFDelayTime: frameDelay]] as CFDictionary

        for time in times {
            let cgImage: CGImage
            do {
                cgImage = try await generator.image(at: time).image
            } catch {
                throw RecordingError.conversionFailed(
                    "Frame generation failed at \(time.seconds)s: \(error.localizedDescription)")
            }
            CGImageDestinationAddImage(destination, cgImage, frameProperties)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw RecordingError.conversionFailed("Could not finalize GIF at \(gifURL.path)")
        }
    }
}
