import Foundation

public enum UploadFeedback {
    /// What to write to the log for a failed upload.
    ///
    /// Diagnostics need more than the user-facing text — "Couldn't complete the
    /// connection" discards the reason an SFTP upload failed, which is what made
    /// one undiagnosable — but they must not carry response bodies. A server can
    /// echo the request back on an error, so a rejected upload's body may contain
    /// an API key, a signed URL or a deletion token, and the log is an ordinary
    /// file in ~/Library/Logs, outside the Keychain.
    ///
    /// So: keep the status, the case, and messages this app composed itself;
    /// drop anything the server said.
    public static func diagnostic(for error: Error) -> String {
        guard let error = error as? UploadError else {
            if let error = error as? URLError { return "URLError(\(error.code.rawValue))" }
            return String(describing: type(of: error))
        }
        switch error {
        // The body is deliberately dropped, not truncated: a credential can sit
        // anywhere in it.
        case .http(let status, _): return "HTTP \(status) (response body withheld)"
        case .emptyURL: return "no usable URL in the response"
        case .unsupported(let reason): return "unsupported: \(reason)"
        case .missingCredential(let account): return "missing credential: \(account)"
        // Composed by our own transports, which redact the underlying network or
        // SSH error down to a typed category/status code before wrapping it — so
        // the reason names the actual cause and carries nothing the server sent.
        // (An SFTP server's status message, for one, can echo a path or a token.)
        case .transport(let reason): return "transport: \(reason)"
        case .badResponse(let reason): return "bad response: \(reason)"
        case .hostKeyMismatch: return "SSH host key mismatch"
        case .destinationRejectsVideo(let name): return "\(name) does not accept video"
        }
    }

    /// Never surface raw server responses: they can echo request credentials.
    public static func message(for error: Error) -> String {
        if let error = error as? UploadError {
            switch error {
            case .http(let status, _):
                switch status {
                case 401: return "The server rejected the credentials. Check the API key or login."
                case 403: return "Access was denied. Check the credentials and destination permissions."
                case 404: return "The upload endpoint or bucket wasn’t found. Check the destination settings."
                case 413: return "The file is larger than this server allows."
                case 429: return "The server is limiting requests. Wait a moment and try again."
                case 500...599: return "The server is having trouble (HTTP \(status)). Try again later."
                default: return "The server refused the upload (HTTP \(status))."
                }
            case .missingCredential: return "Required credentials are missing. Edit this uploader and save them again."
            case .hostKeyMismatch: return "The SSH host key changed. Verify the server’s identity before updating this uploader."
            case .transport: return "Couldn’t complete the connection. Check the network, server address, and login."
            case .emptyURL, .badResponse: return "The server responded, but no usable upload link was returned. Check the uploader configuration."
            case .unsupported: return "This uploader or file configuration isn’t supported. Check its settings and file size."
            case .destinationRejectsVideo(let name):
                return "\(name) only accepts images, so it can’t take a screen recording. "
                    + "Choose a different destination under Uploads → Screen recordings."
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet: return "You’re offline. Connect to the internet and try again."
            case .timedOut: return "The server took too long to respond. Try again."
            case .cannotFindHost, .cannotConnectToHost: return "Couldn’t reach the server. Check its address and your connection."
            default: return "The network request failed. Check your connection and try again."
            }
        }
        if error is CancellationError { return "The upload was cancelled." }
        return "Couldn’t upload the file. Check that it still exists and that the uploader is configured correctly."
    }
}
