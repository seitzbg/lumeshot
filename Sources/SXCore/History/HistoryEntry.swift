import Foundation

public struct HistoryEntry: Equatable, Sendable, Identifiable {
    public var id: String
    public var capturedAt: Date
    public var filePath: String?
    public var url: String?
    public var deletionURL: String?
    public var destinationName: String?
    public var uploadFailed: Bool

    public init(id: String, capturedAt: Date, filePath: String?, url: String?,
                deletionURL: String?, destinationName: String?, uploadFailed: Bool) {
        self.id = id
        self.capturedAt = capturedAt
        self.filePath = filePath
        self.url = url
        self.deletionURL = deletionURL
        self.destinationName = destinationName
        self.uploadFailed = uploadFailed
    }
}
