import Foundation
import LumeshotCore

public protocol Uploader: Sendable {
    func upload(_ file: FilePart) async throws -> UploadResult
}
