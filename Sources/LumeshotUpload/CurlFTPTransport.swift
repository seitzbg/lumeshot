import Clibcurl
import Foundation
import LumeshotCore

/// Real FTP/FTPS transport over system libcurl. `CURL*` is a non-Sendable raw
/// pointer, so every use of it is confined to the `DispatchQueue.global`
/// closure below — it never crosses the `async` boundary or gets stored.
public struct CurlFTPTransport: FTPTransport {
    public init() {}

    // VERIFY on Mac: CURL_GLOBAL_DEFAULT is a C macro; depending on how libcurl's
    // headers bridge into Swift on the actual SDK, `Int(CURL_GLOBAL_DEFAULT)` may
    // need to become `Int32(CURL_GLOBAL_DEFAULT)` (or no cast at all) for
    // `curl_global_init` to typecheck — adjust the cast only, not the once-per-
    // process structure.
    private static let globalInit: Void = { _ = curl_global_init(Int(CURL_GLOBAL_DEFAULT)) }()

    public func upload(_ data: Data, to url: String, username: String, password: String,
                       useTLS: Bool) async throws {
        _ = Self.globalInit
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {   // blocking libcurl off the cooperative pool
                guard let curl = curl_easy_init() else {
                    cont.resume(throwing: UploadError.transport("curl_easy_init failed")); return
                }
                defer { curl_easy_cleanup(curl) }
                var state = ReadState(data: data, offset: 0)
                let rc: CURLcode = withUnsafeMutablePointer(to: &state) { sp in
                    _ = url.withCString { clibcurl_set_string(curl, CURLOPT_URL, $0) }
                    _ = username.withCString { clibcurl_set_string(curl, CURLOPT_USERNAME, $0) }
                    _ = password.withCString { clibcurl_set_string(curl, CURLOPT_PASSWORD, $0) }
                    _ = clibcurl_set_upload(curl, 1)
                    _ = clibcurl_set_long(curl, CURLOPT_FTP_CREATE_MISSING_DIRS, 1)
                    // An unreachable/stalled server would otherwise block curl_easy_perform
                    // forever, leaving the continuation unresumed — fail loud instead.
                    _ = clibcurl_set_long(curl, CURLOPT_CONNECTTIMEOUT, 30)
                    // A stalled mid-transfer (server stops reading, dead connection after connect) would otherwise
                    // hang curl_easy_perform forever — abort if throughput < 1 byte/sec for 60 consecutive seconds.
                    _ = clibcurl_set_long(curl, CURLOPT_LOW_SPEED_LIMIT, 1)
                    _ = clibcurl_set_long(curl, CURLOPT_LOW_SPEED_TIME, 60)
                    _ = clibcurl_set_infilesize(curl, curl_off_t(data.count))
                    // VERIFY on Mac: confirm `CURLUSESSL_ALL.rawValue` is how Swift
                    // imports this C enum on the actual SDK — some libcurl headers
                    // expose CURLUSESSL_ALL as a plain Int32 constant instead of a
                    // RawRepresentable enum, in which case drop `.rawValue`.
                    if useTLS { _ = clibcurl_set_long(curl, CURLOPT_USE_SSL, Int(CURLUSESSL_ALL.rawValue)) }
                    _ = clibcurl_set_readfunc(curl, UnsafeMutableRawPointer(sp)) { buf, size, nitems, ud in
                        guard let ud else { return 0 }
                        let st = ud.assumingMemoryBound(to: ReadState.self)
                        let remaining = st.pointee.data.count - st.pointee.offset
                        let want = min(remaining, size * nitems)
                        guard want > 0 else { return 0 }
                        st.pointee.data.withUnsafeBytes { raw in
                            _ = memcpy(buf, raw.baseAddress!.advanced(by: st.pointee.offset), want)
                        }
                        st.pointee.offset += want
                        return want
                    }
                    return curl_easy_perform(curl)
                }
                if rc == CURLE_OK {
                    cont.resume()
                } else {
                    cont.resume(throwing: UploadError.transport(
                        "FTP upload failed: \(String(cString: curl_easy_strerror(rc))) (curl \(rc.rawValue))"))
                }
            }
        }
    }

    /// The read-callback's `userdata` pointer targets this type. Confined
    /// entirely to the `DispatchQueue.global` closure above via
    /// `withUnsafeMutablePointer` — never crosses an actor/Sendable boundary.
    private struct ReadState {
        var data: Data
        var offset: Int
    }
}
