import Foundation
import Testing
@testable import SXCore

private final class DictCredentialStore: CredentialStore, @unchecked Sendable {
    var store: [String: String] = [:]
    func secret(for account: String) throws -> String? { store[account] }
    func setSecret(_ value: String, for account: String) throws { store[account] = value }
    func deleteSecret(for account: String) throws { store[account] = nil }
}

@Suite struct SecretVaultTests {
    private func configWithSecretsEverywhere() -> CustomUploaderConfig {
        var c = CustomUploaderConfig(requestURL: "https://up")
        c.headers = ["Authorization": "Bearer HSECRET", "Accept": "application/json"]
        c.arguments = ["apikey": "ASECRET", "album": "shots"]
        c.parameters = ["access_token": "PSECRET", "pretty": "1"]
        c.data = #"{"token":"DSECRET"}"#
        return c
    }

    @Test func stripRemovesEverySecretFromThePersistedConfig() throws {
        let creds = DictCredentialStore()
        let stripped = try SecretVault.strip(configWithSecretsEverywhere(), id: "d1", into: creds)

        // The serialized config (what lands in settings.json) contains NO raw secret.
        let json = String(data: try JSONEncoder().encode(stripped), encoding: .utf8)!
        for secret in ["HSECRET", "ASECRET", "PSECRET", "DSECRET"] {
            #expect(!json.contains(secret))
        }
        // Secret slots hold the sentinel across all four surfaces.
        #expect(stripped.headers["Authorization"] == SecretVault.sentinel)
        #expect(stripped.arguments["apikey"] == SecretVault.sentinel)
        #expect(stripped.parameters["access_token"] == SecretVault.sentinel)
        #expect(stripped.data == SecretVault.sentinel)
        // Non-secret values are preserved verbatim.
        #expect(stripped.headers["Accept"] == "application/json")
        #expect(stripped.arguments["album"] == "shots")
        #expect(stripped.parameters["pretty"] == "1")
        // The real secrets live in the store (the data body is stored wholesale).
        #expect(creds.store.values.contains("PSECRET"))
        #expect(creds.store.values.contains(#"{"token":"DSECRET"}"#))
    }

    @Test func injectIsTheLosslessInverseOfStrip() throws {
        let creds = DictCredentialStore()
        let original = configWithSecretsEverywhere()
        let stripped = try SecretVault.strip(original, id: "d1", into: creds)
        let injected = try SecretVault.inject(stripped, id: "d1", from: creds)
        #expect(injected == original)
    }

    @Test func sameNamedFieldsAcrossSurfacesDoNotCollide() throws {
        let creds = DictCredentialStore()
        var c = CustomUploaderConfig(requestURL: "https://up")
        c.headers = ["token": "HEADER-TOK"]
        c.arguments = ["token": "ARG-TOK"]
        let stripped = try SecretVault.strip(c, id: "d1", into: creds)
        let injected = try SecretVault.inject(stripped, id: "d1", from: creds)
        #expect(injected.headers["token"] == "HEADER-TOK")   // not cross-contaminated
        #expect(injected.arguments["token"] == "ARG-TOK")
    }

    @Test func injectThrowsWhenAStoredSecretIsMissing() {
        let creds = DictCredentialStore()
        var c = CustomUploaderConfig(requestURL: "https://up")
        c.headers = ["Authorization": SecretVault.sentinel]   // sentinel but nothing stored
        #expect(throws: UploadError.self) {
            _ = try SecretVault.inject(c, id: "d1", from: creds)
        }
    }

    @Test func isSecretKeyCoversCommonNamesAndSkipsPlainOnes() {
        for k in ["Authorization", "X-Api-Key", "access_token", "password", "Cookie", "bearer"] {
            #expect(SecretVault.isSecretKey(k))
        }
        #expect(!SecretVault.isSecretKey("album"))
        #expect(!SecretVault.isSecretKey("pretty"))
    }

    @Test func purgeDeletesEveryStoredSecretAccount() throws {
        let creds = DictCredentialStore()
        let stripped = try SecretVault.strip(configWithSecretsEverywhere(), id: "d1", into: creds)
        #expect(!creds.store.isEmpty)                 // secrets were stored
        try SecretVault.purge(stripped, id: "d1", from: creds)
        #expect(creds.store.isEmpty)                  // every namespaced account removed
    }
}
