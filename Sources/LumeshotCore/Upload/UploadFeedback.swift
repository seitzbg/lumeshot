import Foundation

public enum UploadFeedback {
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
