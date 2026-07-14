import Foundation

public struct CaptureArtifact: Sendable {
    public let pngData: Data
    public let width: Int
    public let height: Int
    public let capturedAt: Date
    public let appName: String?

    public init(pngData: Data, width: Int, height: Int, capturedAt: Date, appName: String?) {
        self.pngData = pngData
        self.width = width
        self.height = height
        self.capturedAt = capturedAt
        self.appName = appName
    }
}
