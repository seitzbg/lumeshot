# Lumeshot code review

Reviewed 2026-09-06 at commit `09fa276` (`picsur-destination`). The review covered all production Swift targets, packaging/development scripts, GitHub workflows, and the tests relevant to each execution path.

## Executive summary

The repository is well partitioned and unusually well tested for its size (301 `@Test` declarations across 59 suites). The pure geometry, request construction, settings, credential helpers, and annotation state machine are generally easy to reason about. No committed credentials were found by the static secret scan.

The main risks are at boundaries that the unit tests do not exercise: live transport trust, coordination between the settings file and Keychain, large recording delivery, and `@MainActor` state transitions around suspension points. I found five high-severity and thirteen medium/low-severity issues. The SFTP trust issue is already acknowledged in `docs/ROADMAP.md`; it remains high severity for a release even though it is known.

## High-severity findings

### H1. SFTP accepts every host key

[`CitadelSFTPTransport.swift:51`](Sources/LumeshotUpload/CitadelSFTPTransport.swift#L51) connects with `hostKeyValidator: .acceptAnything()`. That removes SSH's server-authentication guarantee. An active network attacker can impersonate the configured host, receive password authentication or a private-key authentication attempt, and receive or replace the uploaded capture.

Recommendation: use a known-hosts validator or implement trust-on-first-use with the fingerprint stored in Keychain/settings and a user-visible confirmation. A changed key must fail closed and show both the saved and presented fingerprints. Add an integration test for first trust, matching trust, and changed-key rejection.

### H2. Disabling automatic disk saves also defeats explicit Save and the local-first upload invariant

`AfterCapturePipeline` correctly skips the write when `saveToDisk` is false ([`AfterCapturePipeline.swift:28-35`](Sources/LumeshotCore/AfterCapturePipeline.swift#L28-L35)), but both persistence-oriented editor actions are routed through that same settings-controlled pipeline ([`CaptureCoordinator.swift:152-178`](Sources/LumeshotApp/CaptureCoordinator.swift#L152-L178)). Therefore:

- Clicking the editor's explicit **Save** button does not save a file when the global automatic-save toggle is off, despite `EditorAction.save` being documented as “disk + history.”
- Clicking **Upload**, or using automatic upload, still uploads when `savedURL` is nil because `willUpload` does not require a saved file ([`CaptureCoordinator.swift:223-241`](Sources/LumeshotApp/CaptureCoordinator.swift#L223-L241)). The fallback name is `capture.png`, and the history row has no local path.
- `finishPersist` returns `true` even when no file was persisted ([`CaptureCoordinator.swift:198-203`](Sources/LumeshotApp/CaptureCoordinator.swift#L198-L203)), so the CLI/fullscreen completion count can claim files were produced when none were written.

This contradicts both the explicit editor actions and the documented “disk write always precedes upload” safety property. An upload failure can leave no durable artifact.

Recommendation: separate explicit editor actions from automatic after-capture preferences. `.save` and `.upload` should force a collision-safe disk write; automatic upload should either force a local write too or be disabled when `saveToDisk` is off. Only insert a non-upload history row when it has a local path, and derive the reported persisted count from `savedURL != nil`. Add coordinator-level tests for all three editor actions with `saveToDisk` both on and off.

### H3. Uploading a recording reads the entire, unbounded video into memory on the main actor

`RecordingDelivery.deliver` is `@MainActor`, calls `Data(contentsOf:)`, and passes the complete byte buffer to the uploader ([`RecordingDelivery.swift:27-38`](Sources/LumeshotCore/RecordingDelivery.swift#L27-L38), [`RecordingDelivery.swift:59-63`](Sources/LumeshotCore/RecordingDelivery.swift#L59-L63)). The `Uploader`/`FilePart` APIs require `Data`, and multipart construction may copy it again. Recording duration and file size are not capped.

A long or high-resolution recording can freeze the menu-bar UI during the synchronous read and can terminate the process through memory pressure before upload begins. S3 also hashes the whole in-memory body, and the SFTP/FTP transports likewise start from a complete `Data` value.

Recommendation: add a file-backed upload path (`URL` plus MIME/name/size), stream HTTP bodies and FTP/SFTP reads, and compute the S3 hash incrementally. Move all file I/O and hashing off `MainActor`. If streaming cannot be implemented immediately, enforce a documented file-size ceiling and request confirmation before allocating.

### H4. Imported custom-uploader secrets are not guaranteed to stay out of `settings.json`

`SecretVault` calls its detection a heuristic and only scans map entries whose *key* contains one of a short list of substrings ([`SecretVault.swift:14-21`](Sources/LumeshotCore/Upload/SecretVault.swift#L14-L21), [`SecretVault.swift:80-87`](Sources/LumeshotCore/Upload/SecretVault.swift#L80-L87)). It stores the JSON body wholesale, but it never inspects or protects `requestURL`, `fileFormName`, response templates, or values under innocently named map keys ([`SecretVault.swift:24-38`](Sources/LumeshotCore/Upload/SecretVault.swift#L24-L38)). For example, a token embedded in `RequestURL` or under a key such as `session_id` is persisted verbatim by `SettingsStore`.

This violates the categorical Security promise in the README that `.sxcu` secrets are stored “only in the login Keychain.” It also creates a secondary leak path because an invalid URL error can include the fully injected request URL in the application log.

Recommendation: do not infer secrecy from names when making a hard security guarantee. The simplest safe design is to keep the complete imported uploader configuration in Keychain and persist only an opaque reference plus non-sensitive display metadata. Alternatively, require the user to classify fields and defensively encrypt/protect the settings file. Add adversarial tests for credentials in the URL, arbitrary parameter names, and literal sentinel values.

### H5. Recording start/stop is re-entrant across actor suspension points

`ScreenRecorder.start` checks `.idle`, installs the new stream into shared properties, awaits `startCapture()`, and only then sets `.recording` ([`ScreenRecorder.swift:43-85`](Sources/LumeshotRecord/ScreenRecorder.swift#L43-L85)). Main-actor methods are re-entrant while awaiting, so a second `start` can pass the same idle guard and overwrite `stream`, `outputURL`, and `onFinish` while the first start is suspended. The current test only invokes the second start after the first has completed ([`ScreenRecorderTests.swift:107-123`](Tests/LumeshotRecordTests/ScreenRecorderTests.swift#L107-L123)), so it does not cover this window.

The app makes this reachable for region/window recordings: it clears `isPresentingOverlay` before starting an async content lookup ([`RecordingCoordinator.swift:103-110`](Sources/LumeshotApp/RecordingCoordinator.swift#L103-L110), [`RecordingCoordinator.swift:152-159`](Sources/LumeshotApp/RecordingCoordinator.swift#L152-L159)). During that lookup the recorder is still idle and another hotkey/menu action can start a second selection. Repeated stop actions can similarly call `stopCapture()` more than once because state remains `.recording` until a delegate callback resets it.

Recommendation: model the complete lifecycle (`idle`, `selecting`, `starting`, `recording`, `stopping`) and transition synchronously before every `await`. Keep one session token and ignore callbacks from older sessions. Test concurrent starts with a suspendable fake stream and repeated stops before finalization.

## Medium-severity findings

### M1. Destination removal can either destroy live credentials or leave orphans

`DestinationsModel.remove` purges Keychain items before saving the settings change, catches purge errors, and proceeds with the save regardless ([`DestinationsView.swift:50-72`](Sources/LumeshotApp/DestinationsView.swift#L50-L72)). Both failure orders are bad:

- If purge succeeds and settings save fails, the destination remains visible but its credentials are irreversibly gone.
- If purge partly fails and settings save succeeds, the destination disappears while orphaned credentials remain. The multi-key purge helpers also stop at the first deletion error.

The import path has the inverse consistency hole. It writes Keychain entries in `SxcuImporter.makeDestination`, then saves settings without rolling the keys back if the save fails ([`AppDelegate.swift:316-334`](Sources/LumeshotApp/AppDelegate.swift#L316-L334)). `SecretVault.strip` itself does not roll back earlier writes when a later write fails, unlike the S3/SFTP credential helpers.

Recommendation: introduce one coordinator for two-store mutations. Track every account written, compensate on failure, and never remove the durable destination record until credential cleanup succeeds or a retryable tombstone has been saved. Make purge attempt every key and return an aggregate error. Add fault-injection tests at every Keychain and settings-write step.

### M2. History deletion loses the only remote-deletion token before knowing whether deletion worked

`HistoryModel.delete` deletes the SQLite row first, then launches a best-effort `GET` ([`HistoryView.swift:57-68`](Sources/LumeshotApp/HistoryView.swift#L57-L68)). It ignores the returned HTTP status, so 401/404/405/500 responses are treated as success. Invalid deletion URLs are silently skipped, and transport failures are log-only. Because the row is already gone, the user cannot retry and the app has discarded the deletion token. The same action does not remove the local capture file; if README's “local + remote cleanup” means the file rather than the local history row, the UI is also incomplete.

Recommendation: make remote deletion an explicit, status-checked state transition. Retain the row (or a deletion queue) until a 2xx response, show failures, and support the method/auth semantics required by each destination instead of assuming GET. Separately decide and label whether “Delete” removes the history record, the local file, the remote object, or a user-selected combination.

### M3. The recording hotkey cannot remain disabled after persistence

The Preferences clear button writes `record = nil` ([`HotkeyRecorderField.swift:25-33`](Sources/LumeshotApp/HotkeyRecorderField.swift#L25-L33)). Synthesized encoding omits nil optional properties, while the custom decoder maps a missing or null `record` key to the shipped default ([`AppSettings.swift:31-37`](Sources/LumeshotCore/AppSettings.swift#L31-L37)). After the next reload/relaunch, the cleared recording shortcut comes back. The migration tests cover an absent legacy field and a non-nil current field, but not the clear-save-reload round trip.

Recommendation: implement `encode(to:)` so an intentional nil is represented distinctly (for example, an explicit JSON null), and make the decoder default only when `contains(.record)` is false. Add a round-trip regression test starting from `record == nil`.

### M4. Valid response-only `.sxcu` configurations fail with `emptyURL`

`CustomUploaderEngine.parseResult` only succeeds if `config.url` exists and resolves nonempty ([`CustomUploaderEngine.swift:45-57`](Sources/LumeshotCore/Upload/CustomUploaderEngine.swift#L45-L57)). ShareX's custom-uploader documentation explicitly permits leaving URL empty when the response body is already the full URL. Such configurations are therefore valid ShareX files but fail in Lumeshot, despite the advertised `.sxcu` compatibility. See the [official ShareX custom-uploader documentation](https://github.com/ShareX/sharex.github.io/blob/master/docs/custom-uploader.md#url).

Recommendation: when the URL template is absent/empty, use the trimmed response body as the result URL, then validate its scheme/structure. Add fixtures for response-only uploaders and for whitespace-only/invalid responses.

### M5. FTP/SFTP paths and public URLs concatenate unescaped filenames

`NameParser.sanitize` only replaces `/` and `:` ([`NameParser.swift:79-80`](Sources/LumeshotCore/NameParser.swift#L79-L80)); templates using `%pn` can commonly yield spaces and may contain `#`, `?`, `%`, or non-ASCII characters. `RemotePathURLMapper.resultURL` concatenates the filename verbatim, and `FTPUploader` also embeds the raw remote path into the FTP URL ([`RemotePathURLMapper.swift:12-16`](Sources/LumeshotCore/Upload/RemotePathURLMapper.swift#L12-L16), [`FTPUploader.swift:19-24`](Sources/LumeshotUpload/FTPUploader.swift#L19-L24)). Reserved characters can become a fragment/query or make the libcurl URL invalid, while the copied public URL may not address the uploaded object. S3 already performs per-segment encoding and does not have this defect.

Recommendation: keep filesystem/SFTP path joining separate from URL construction. Build FTP and public URLs with `URLComponents` or encode each path segment using an RFC 3986 path-segment set. Add tests for spaces, `#`, `?`, `%`, Unicode, and already-percent-like filenames.

### M6. Editor selection tolerances shrink with image scale while handles do not

Mouse positions are converted from view coordinates into native image coordinates ([`EditorCanvasView.swift:195-213`](Sources/LumeshotApp/EditorCanvasView.swift#L195-L213)), but `hitTolerance` and `handleTolerance` are fixed image-pixel values ([`EditorModel.swift:25-26`](Sources/LumeshotAnnotate/Editor/EditorModel.swift#L25-L26)). Selection handles are always drawn as 8-by-8 view-point circles ([`EditorCanvasView.swift:99-108`](Sources/LumeshotApp/EditorCanvasView.swift#L99-L108)). On a 4K image fitted into a 900-point window, a 9-pixel handle tolerance can be roughly two screen points even though the visible handle is eight points wide, making thin lines and handles unexpectedly hard to select.

Recommendation: define interaction tolerances in view points and divide by `CanvasGeometry.scale` before image-space hit testing, or perform hit testing in view space. Add scale-parametrized tests for 0.1x, 1x, and zoomed-in canvases.

### M7. `showNotification` is ignored for upload outcomes

The still-image upload path unconditionally posts success and failure notifications ([`CaptureCoordinator.swift:242-256`](Sources/LumeshotApp/CaptureCoordinator.swift#L242-L256)). `RecordingDelivery` receives `showNotification` but consults it only for the no-upload “Recording saved” case; upload success/failure always notify ([`RecordingDelivery.swift:52-68`](Sources/LumeshotCore/RecordingDelivery.swift#L52-L68)). Thus the Preferences toggle labeled “Show notification” cannot disable the most frequent upload notifications.

Recommendation: either honor the setting for upload success (and explicitly decide whether failures always surface) or rename/split the preference to describe its actual scope. Add tests for successful and failed uploads with the setting off.

### M8. Release inputs are not reproducible and the release workflow does not test them

`Package.swift` uses semver ranges for three dependencies, but the executable repository does not commit `Package.resolved`. CI and releases can therefore resolve different compatible versions. The release workflow runs only `swift build -c release` before packaging ([`release.yml:13-23`](.github/workflows/release.yml#L13-L23)); it does not run tests, and its `v*` trigger can package a tag that did not pass the main/PR workflow. Third-party actions are version-tag pinned rather than commit-SHA pinned.

Recommendation: commit `Package.resolved`, run `swift test` in the release job, require/reuse an artifact from a successful CI commit, and pin actions by reviewed commit SHA. Emit a checksum alongside the DMG.

### M9. The relaunch flow races the single-instance guard

Permission onboarding starts `open -n <bundle>` and immediately terminates the current process ([`PermissionOnboardingController.swift:64-76`](Sources/LumeshotApp/PermissionOnboardingController.swift#L64-L76)). A newly launched process can reach `terminateIfDuplicateInstance` while the old process is still registered and exit as the “duplicate” ([`AppDelegate.swift:69-88`](Sources/LumeshotApp/AppDelegate.swift#L69-L88)); the old process then exits too. The user is left with no running app after clicking Relaunch.

Recommendation: spawn a small helper that waits for the current PID to exit before opening the bundle, or pass a one-time relaunch token that the duplicate-instance guard understands. Add an integration test/helper-level test around the ordering.

### M10. Picsur host validation accepts malformed values

`PicsurConfig.normalizeHost` only trims text, strips trailing slashes, and prepends `https://` when the input does not start with HTTP ([`PicsurConfig.swift:31-38`](Sources/LumeshotCore/Upload/PicsurConfig.swift#L31-L38)). The Add sheet considers every nonempty normalized string valid ([`DestinationsView.swift:429-431`](Sources/LumeshotApp/DestinationsView.swift#L429-L431)). Inputs such as `ftp://host`, `https://`, or a URL containing a fragment are saved and made active, then fail later during upload (for example, `ftp://host` becomes `https://ftp://host`).

Recommendation: parse with `URLComponents`, require `http` or `https` plus a nonempty host, reject user-info/query/fragment, and make an explicit decision about supported base paths. Return validation errors to the sheet instead of dismissing it unconditionally.

## Low-severity findings

### L1. Failed GIF exports leave partial files and consume future collision names

`GifConverter` creates the destination at the final URL before generating every frame ([`GifConverter.swift:43-64`](Sources/LumeshotRecord/GifConverter.swift#L43-L64)). If frame generation or finalization fails, `HistoryModel` reports an error but never removes the partial file ([`HistoryView.swift:80-98`](Sources/LumeshotApp/HistoryView.swift#L80-L98)). The next export sees that path as occupied and writes `_1.gif`, leaving the damaged artifact behind.

Recommendation: render to a unique temporary sibling, remove it on every error/cancellation path, and atomically move it to the collision-resolved final URL only after finalization.

### L2. The application log grows without bound

`AppLog.log` opens and appends to a single file forever ([`AppLog.swift:7-24`](Sources/LumeshotApp/AppLog.swift#L7-L24)). A long-running menu-bar utility can eventually accumulate a large log, and repeated open/seek/close also adds avoidable per-event overhead.

Recommendation: use unified logging for normal diagnostics and a bounded rotating file only if a support log is required. Apply an age/size cap and avoid logging URLs that may contain credentials.

### L3. An already-created History window keeps stale GIF defaults

`HistoryWindowController` snapshots `RecordingSettings` only when it first creates `HistoryModel`; later `show()` calls reload rows but not settings ([`HistoryWindowController.swift:17-26`](Sources/LumeshotApp/HistoryWindowController.swift#L17-L26)). Changes to GIF FPS/max width in Preferences do not become the sheet defaults until the application restarts.

Recommendation: reload recording settings whenever the window is shown or let `HistoryModel` query the settings store when opening the export sheet.

## Validation performed and limits

The following checks passed locally:

- `bash -n` for all four shell scripts.
- XML parsing of `Resources/Info.plist` with `xmllint`.
- YAML parsing of both GitHub Actions workflows with `yq`.
- `git diff --check`, `git fsck --connectivity-only`, and a static committed-secret scan.

Swift build/tests could not be executed in this review environment: it is Linux/aarch64 and has no Swift toolchain, while the package requires macOS 15 frameworks. The repository's own live ScreenCaptureKit tests self-skip without TCC permission, and SFTP/FTP/Picsur behavior is manual-smoke-only. Those gaps are material because H1, H5, M2, and M9 sit in precisely those unexercised integration paths. The macOS CI and all manual smoke checklists should be run after fixes; current green-CI claims were not independently verified here.

## Suggested fix order

1. H1, H2, H4: close the transport/authentication and data-retention gaps before distributing builds.
2. H3, H5: make recording safe for long files and rapid/repeated UI input.
3. M1-M4: make Keychain/settings and history deletion recoverable, then restore advertised `.sxcu` behavior.
4. M5-M10 and the low-severity items: address interoperability, UI consistency, and release hardening.
