import Foundation
import SXCore

public protocol Uploader: Sendable {
    func upload(_ file: FilePart) async throws -> UploadResult
}
