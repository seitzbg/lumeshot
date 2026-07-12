// M5a dependency spike: forces the Citadel (SFTP) + Clibcurl (FTP) dependency graph to resolve,
// compile, and LINK under the project's swift-tools-version: 6.0 — the go/no-go signal for M5a
// before the full task breakdown. Real SFTP/FTP transports (CitadelSFTPTransport / CurlFTPTransport)
// replace this file in later M5a tasks.
import Foundation
import Citadel
import Clibcurl

enum _DependencySmoke {
    // Reference a Citadel public type so the module is actually linked, not merely resolved.
    static let citadelType: Any.Type = SSHClient.self
    // Reference a libcurl symbol so libcurl is linked via the Clibcurl system module.
    static func curlInit() { _ = curl_easy_init() }
}
