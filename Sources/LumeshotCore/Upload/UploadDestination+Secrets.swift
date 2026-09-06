import Foundation

public extension UploadDestination {
    /// Every Keychain account this destination may occupy.
    ///
    /// One place that knows the mapping, so adding a destination kind cannot
    /// leave removal purging a subset. Accounts that were never written are
    /// harmless: deletion is idempotent and reads simply return nil.
    var secretAccounts: [String] {
        switch kind {
        case .customUploader:
            return customUploader.map { SecretVault.accounts($0, id: id) } ?? []
        case .imgur:
            return []                                   // anonymous client id is not a secret
        case .picsur:
            return PicsurCredentials.accounts(id: id)
        case .s3:
            return S3Credentials.accounts(id: id)
        case .sftp:
            return SFTPCredentials.accounts(id: id)
        case .ftp:
            return FTPCredentials.accounts(id: id)
        }
    }
}
