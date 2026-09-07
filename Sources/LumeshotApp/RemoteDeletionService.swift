import Foundation
import LumeshotCore
import LumeshotUpload

/// Shared by History and the generated-image test so both use the same
/// credentials and verify native providers' API responses before discarding links.
struct RemoteDeletionService {
    let http: HTTPClient
    let credentials: CredentialStore

    func delete(_ deletionURL: String, destination: UploadDestination?) async throws {
        guard let url = URL(string: deletionURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw DeletionError.invalidLink
        }

        if destination?.kind == .picsur || url.path.contains("/api/image/delete/") {
            guard let destination, destination.kind == .picsur,
                  let config = destination.picsurConfig, config.isValid else {
                throw DeletionError.missingDestination
            }
            // Only use this destination's credentials for its configured server.
            // Construct the POST URL from settings, never from the returned link.
            let prefix = "\(config.host)/api/image/delete/"
            guard deletionURL.hasPrefix(prefix), url.query == nil, url.fragment == nil else {
                throw DeletionError.invalidLink
            }
            let parts = deletionURL.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
                  UUID(uuidString: String(parts[0])) != nil else {
                throw DeletionError.invalidLink
            }
            let id = String(parts[0])
            let secret = try PicsurCredentials.load(id: destination.id, from: credentials)
            let body = try JSONEncoder().encode(PicsurDeleteRequest(id: id, key: String(parts[1])))
            // Picsur's GET link redirects to an HTML success/failure page; its
            // POST API reports errors directly and requires the saved API key.
            // https://github.com/CaramelFur/Picsur/blob/master/backend/src/routes/image/image-manage.controller.ts
            let response = try await http.send(PreparedRequest(method: .post,
                url: "\(config.host)/api/image/delete/key",
                headers: ["Authorization": "Api-Key \(secret.apiKey)"],
                body: body, contentType: "application/json"))
            try checkStatus(response.status)
            guard let confirmation = try? JSONDecoder().decode(PicsurDeleteResponse.self, from: response.body),
                  confirmation.success, confirmation.data.id == id else {
                throw DeletionError.unconfirmed
            }
        } else if destination?.kind == .imgur || url.host?.lowercased() == "imgur.com" {
            guard let destination, destination.kind == .imgur,
                  let clientID = destination.imgurClientID, !clientID.isEmpty else {
                throw UploadError.missingCredential("Imgur client ID")
            }
            let prefix = "https://imgur.com/delete/"
            guard deletionURL.hasPrefix(prefix) else { throw DeletionError.invalidLink }
            let hash = String(deletionURL.dropFirst(prefix.count))
            guard !hash.isEmpty, hash.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            }) else { throw DeletionError.invalidLink }
            let response = try await http.send(PreparedRequest(method: .delete,
                url: "https://api.imgur.com/3/image/\(hash)",
                headers: ["Authorization": "Client-ID \(clientID)"]))
            try checkStatus(response.status)
            guard let confirmation = try? JSONDecoder().decode(ImgurDeleteResponse.self, from: response.body),
                  confirmation.success, confirmation.data else { throw DeletionError.unconfirmed }
        } else {
            let response = try await http.send(PreparedRequest(method: .get, url: deletionURL))
            try checkStatus(response.status)
            // Custom deletion links can lead to a web confirmation form. A
            // successfully loaded HTML page is not evidence of remote deletion.
            let contentType = response.headers.first { $0.key.lowercased() == "content-type" }?.value ?? ""
            let bodyStart = String(decoding: response.body.prefix(256), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !contentType.lowercased().contains("text/html"), !bodyStart.hasPrefix("<") else {
                throw DeletionError.unconfirmed
            }
        }
    }

    private func checkStatus(_ status: Int) throws {
        // A missing route or a wrong delete key can also produce 404: neither
        // proves the image was deleted, so keep its link for the user.
        guard (200..<300).contains(status) else { throw UploadError.http(status: status, body: "") }
    }

    static func message(for error: Error) -> String {
        if let error = error as? DeletionError { return error.localizedDescription }
        if case UploadError.http(let status, _) = error, status == 404 || status == 410 {
            return "The server couldn’t find the image or deletion endpoint. Check the image on your hosting service."
        }
        return UploadFeedback.message(for: error)
    }

    private struct PicsurDeleteRequest: Encodable { let id: String; let key: String }
    private struct ImgurDeleteResponse: Decodable { let success: Bool; let data: Bool }
    private struct PicsurDeleteResponse: Decodable {
        let success: Bool
        let data: DeletedImage
        struct DeletedImage: Decodable { let id: String }
    }
    private enum DeletionError: LocalizedError {
        case invalidLink, missingDestination, unconfirmed
        var errorDescription: String? {
            switch self {
            case .invalidLink: return "The deletion link doesn’t match this uploader’s server. Remove the image through your hosting service."
            case .missingDestination: return "The original Picsur uploader is unavailable. Restore it in Settings or remove the image through your hosting service."
            case .unconfirmed: return "The server didn’t confirm deletion. Check the image on your hosting service before trying again."
            }
        }
    }
}
