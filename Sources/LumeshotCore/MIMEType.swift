import Foundation

/// Maps a filename extension to the MIME type used for uploads. Unknown
/// extensions fall back to "application/octet-stream" (never a silent guess
/// at a more specific type).
public enum MIMEType {
    public static func forExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    /// True for the recording file extensions History can show. ImageIO cannot
    /// downsample a video frame, so History uses this to fall back to a film
    /// icon rather than attempting (and silently failing at) a thumbnail decode.
    public static func isVideo(path: String) -> Bool {
        ["mp4", "mov"].contains((path as NSString).pathExtension.lowercased())
    }
}
