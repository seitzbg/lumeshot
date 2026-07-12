import Foundation

public struct RecordingSettings: Codable, Equatable, Sendable {
    /// Capture system (device) audio into the recording. Uses Screen Recording TCC (already granted); no mic prompt.
    public var systemAudio: Bool
    /// H.264 vs HEVC. Stored as a stable string; default h264 for broad compatibility.
    public var videoCodec: VideoCodec
    /// Default fps for GIF export sheet.
    public var gifFPS: Int
    /// Default max width (px) for GIF export; nil = source width.
    public var gifMaxWidth: Int?

    public enum VideoCodec: String, Codable, Equatable, Sendable { case h264, hevc }

    public init(systemAudio: Bool = false,
                videoCodec: VideoCodec = .h264,
                gifFPS: Int = 15,
                gifMaxWidth: Int? = 640) {
        self.systemAudio = systemAudio
        self.videoCodec = videoCodec
        self.gifFPS = gifFPS
        self.gifMaxWidth = gifMaxWidth
    }

    public static let `default` = RecordingSettings()
}
