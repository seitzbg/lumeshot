# Lumeshot implementation map

Responsibilities and behavior of the Swift types in this repository.

| Swift (this repo) | Notes |
|---|---|
| `LumeshotCore/AppSettings` | Tiny M1 subset; grows per milestone. Includes `HotkeySettings`/`HotkeyCombo` (Carbon keyCode + modifier mask), defaulted to ⌥⇧3/4/5 (keyCodes 20/21/23, modifiers 2560 = option+shift) to avoid colliding with the system ⌘⇧3/4/5 screenshot shortcuts |
| `LumeshotCore/SettingsStore` | Corrupt settings are backed up and errors surfaced. `SettingsLoadIssue` has three cases — `.corruptBackedUp`, `.corruptBackupFailed` (backup itself failed, corrupt file left in place), `.readFailed` (file exists but unreadable) — all three are logged and surfaced as a notification by `AppDelegate.handleLoadIssue` |
| `LumeshotCore/NameParser` | M1 tokens: %y %mo %d %h %mi %s %ms %rn %ra %width %height %pn %i. `%n` intentionally omitted — define its behavior before adding support |
| `LumeshotCore/CaptureArtifact` | Plain value type carrying PNG bytes + dimensions + capture time + owning app name between the capture layer and the after-capture pipeline |
| `LumeshotCore/AfterCapturePipeline` | M1 chain: save → clipboard → notify, driven by the `PipelineEffects` protocol (file I/O, clipboard, notifications) so the pipeline is unit-testable without AppKit; upload chain lands in M2 |
| `LumeshotCapture/CapturePermission` | Wraps `CGPreflightScreenCaptureAccess`/`CGRequestScreenCaptureAccess` and the System Settings deep-link |
| `LumeshotCapture/ImageEncoder` | Thin wrapper over `ImageIO`/`CGImageDestination` |
| `LumeshotCapture/DisplayCapture` | GDI BitBlt → SCScreenshotManager. Captures every display, matching each `SCDisplay` back to its `NSScreen` for backing scale/frame; falls back to scale 2 and a synthesized frame if no match is found |
| `LumeshotCapture/WindowCapture`/`WindowFilter` | EnumWindows → SCShareableContent. `WindowFilter.selectable` drops non-normal-layer, off-screen, sub-50px, and unowned/self windows, sorted largest-first so picker hit-testing (last match wins) resolves to the smallest window under the cursor. Capture resolves the target window's own display scale rather than assuming the primary display's |
| `LumeshotCapture/CaptureGeometry` | Drag-to-rect normalization and view-point → pixel-crop-rect scaling/clamping shared by the region overlay |
| `LumeshotApp/RegionOverlay` (`RegionOverlaySession`) | Freeze-frame model; single-display selection in M1. One borderless `.screenSaver`-level window per display; Esc cancels; a click without a ≥4pt drag is ignored (overlay stays up); drag-release crops and completes |
| `LumeshotApp/WindowPickerSession` | Transparent full-screen overlays per screen; hover highlights the window under the cursor with an app/title label, click captures, Esc cancels |
| `LumeshotApp/HotkeyManager` | RegisterHotKey → Carbon `RegisterEventHotKey`/`InstallEventHandler`. Resolves its Carbon-callback target through a weak `current` static (not an unretained pointer) so a deallocated instance degrades to a no-op instead of a dangling dereference |
| `LumeshotApp/PermissionOnboardingController` | `isGranted()` for a side-effect-free check, `ensurePermission()` to prompt + show the onboarding window (System Settings deep-link, Relaunch) when not yet granted |
| `LumeshotApp/AppPipelineEffects` | Implements `PipelineEffects` against real `NSPasteboard`/`UNUserNotificationCenter`; notification click reveals the saved file in Finder. Notifications are inert when not running from a bundle (bare `swift run` has no bundle identifier) |
| `LumeshotApp/CaptureCoordinator` | `init(settingsStore:effects:)`. Fullscreen/region/window entry points, each preflighting permission via `PermissionOnboardingController`. Region and window capture guard against double-trigger with an in-flight flag plus a "session already open" check, since a stray second hotkey press or menu click while an overlay is up must not spawn a second overlay. `deliver(image:appName:onOutcome:)` always performs delivery, then reports persistence through an optional callback. The CLI uses that callback to count saved files. Fullscreen captures every display, delivering one artifact each; the last display's capture wins the clipboard |
| `LumeshotApp/StatusItemController` | Menu-bar `NSStatusItem` with the capture menu |
| `LumeshotApp/AppDelegate.registerHotkeys` | Wires the three `AppSettings.hotkeys` combos to the coordinator's capture entry points at launch (⌥⇧3/4/5 → fullscreen/region/window) |
| `LumeshotApp/AppLog` | Tees diagnostics to `NSLog` and a file at `~/Library/Logs/Lumeshot.log`, because a menu-bar app launched from Finder (not a terminal) has no visible stderr; this file is the primary post-hoc diagnostic source (see `docs/smoke-m1.md`) |
| `LumeshotCore/Upload/CustomUploaderConfig` | PascalCase-keyed `Codable` mirror of the `.sxcu` JSON schema (RequestURL/Headers/Body/Arguments/RegexList/…). `parse(_:)` rejects unsupported `Body` values (e.g. `XML`) before decoding, since the Swift enum can't model them |
| `LumeshotCore/Upload/CustomUploaderEngine` | M2a subset of the token/function language: static request preparation (parameters/headers/arguments) only — no `{input}`/`{prompt}` interactive functions, documented as a known limitation in `docs/smoke-m2a.md` notes |
| `LumeshotCore/Upload/RequestBodyEncoder` | Builds the `MultipartFormData`/`FormURLEncoded`/`JSON`/`Binary` request bodies matching `CustomUploaderBody` |
| `LumeshotCore/Upload/ResponseURLParser` | Resolves `$json:path$`/`$regex:n$`/header/literal tokens against the upload response to produce the final URL |
| `LumeshotCore/Upload/UploadDestination`, `UploadSettings` | One `UploadDestination` per configured target (custom uploader, Imgur, or S3); `activeDestinationID` selects the current image uploader. `customUploader.headers`/`.arguments` hold non-secret values only — secret values are the `$keychain$` sentinel (`UploadService.secretSentinel`), resolved at upload time |
| `LumeshotCore/Upload/CredentialStore` (protocol), `LumeshotApp/KeychainCredentialStore` | Deliberate divergence: instead of encrypting secret fields in place inside `settings.json`, secrets are moved out entirely into the macOS login Keychain at `"<destinationID>/<key>"` (service `org.lumeshot.app`), leaving only the sentinel on disk |
| `LumeshotApp/UploadService` | Builds an `Uploader` (custom, Imgur, or S3) per destination, rehydrating `$keychain$` (and S3) secrets via `CredentialStore` immediately before the request; called as a fire-and-forget task after the local save so upload never gates or blocks it |
| `LumeshotApp/SxcuImporter` | Parses a `.sxcu`, moves header/argument values matching a secret-key heuristic (`Authorization`/`*Token*`/`*Key*`/`*Secret*`, case-insensitive) into the Keychain, and returns an `UploadDestination` with the sentinel in place of each secret |
| `LumeshotCore/History/HistoryStore`, `HistoryEntry` | SQLite-backed capture/upload history at `~/Library/Application Support/Lumeshot/history.sqlite`; one row per capture, updated in place with the resolved URL/failure state once an upload completes or fails |
| `scripts/setup-signing.sh` | One-time: creates a dedicated `lumeshot-signing.keychain-db` with a self-signed `lumeshot-dev` code-signing identity, so the ssh dev loop (`scripts/remote.sh`) can codesign non-interactively (the login keychain is locked to non-interactive ssh sessions) with a *stable* identity — TCC keys the Screen Recording grant off the cert identity, so a stable signature (unlike ad-hoc, which changes every build) means the grant survives rebuilds |
| `scripts/bundle.sh` | Assembles `dist/Lumeshot.app` and signs it: prefers the dedicated dev signing identity from `setup-signing.sh` when its keychain and password file are present, otherwise falls back to ad-hoc signing (`-`) — this is the path CI and any machine without the dev keychain take |
| `LumeshotCore/Upload/SigV4Signer` | Hand-rolled SigV4 via CryptoKit HMAC-SHA256; signs upload requests using AWS Signature Version 4 for S3-compatible endpoints (AWS/R2/MinIO/B2); used by `S3Uploader` |
| `LumeshotCore/Upload/S3RequestBuilder` | Builds signed PUT requests with metadata, custom headers, optional ACL, and path-based or virtual-host S3 addressing |
| `LumeshotCore/Upload/S3Uploader` | Orchestrates S3 upload (multipart request via `S3RequestBuilder`, sign via `SigV4Signer`, HTTP request, response parsing, result-URL resolution); supports custom endpoints (R2/MinIO/B2) |
| `LumeshotCore/Upload/S3Config` | Destination settings: endpoint URL, bucket, region, optional ACL header, result-URL domain (for CDN/reverse-proxy addressing); path-based vs virtual-host mode determined by endpoint format |
| `LumeshotCore/Upload/S3Credentials` (signer key type) | Access/secret keypair; stored encrypted in the login Keychain (`SecretVault`), never in `settings.json` |
| `LumeshotApp/SecretVault.purge` | Removes all Keychain entries for a destination (`<destinationID>/*`) when the destination is deleted |
| `LumeshotApp/UploadSettings` helpers (add/remove/setActive) | Manage in-memory destination list: add/remove/select actions; removal also purges Keychain secrets via `SecretVault.purge`; active destination ID persisted in `settings.json` |
| `LumeshotApp/DestinationsView` | SwiftUI destination-management window: lists destinations with an active-selection radio and a per-row delete (purges Keychain secrets on remove); "Add S3…"/"Add Imgur…" open entry forms; `.sxcu` import stays on the menu-bar item; supports editing existing destinations |
| `LumeshotApp/DestinationsModel` (view model) | Manages the destination list lifecycle: add, remove, select, import `.sxcu`; rehydrates secrets from Keychain on load; observes settings changes so UI updates if external config changes |
| `LumeshotApp/HistoryView` | SwiftUI history browser: list with thumbnails, search by filename/URL, actions (Copy URL, Open, Reveal, Delete); delete removes local row and fires remote deletion URL if present |
| `LumeshotApp/HistoryModel` (view model) | Loads all entries from `HistoryStore.all`, filters by search query, handles delete (local + remote cleanup) |
| `LumeshotCore/History/HistoryStore.all`, `.search` | SQLite query helpers: `.all` retrieves all rows in reverse-chronological order; `.search(query)` does substring match on filename and URL fields |

## Editor (M3a)

| Swift (this repo) | Notes |
|---|---|
| `LumeshotAnnotate/Model/Annotation` | Value-type `struct` containing shape and style; z-order follows array order (append = topmost). |
| `LumeshotAnnotate/Model/AnnotationShape` | Closed enum for vector shapes, crop, text, highlighter, effects, and step badges. Arrows use one classic arrowhead style; multi-point shapes use straight segments. |
| `LumeshotAnnotate/Geometry/Annotation+Geometry` | `hitTest(_:tolerance:)`/`bounds` computed per shape case (inflated-rect, normalized-ellipse, point-to-segment) — same tolerance-based approach as the reference, collapsed into one `switch` instead of one override per subclass |
| `LumeshotAnnotate/Geometry/Annotation+Handles` | Eight box handles and two endpoint handles; rotation is deferred. |
| `LumeshotAnnotate/History/AnnotationHistory` | Value-snapshot undo/redo stacks, bounded to 50 entries. Each snapshot copies the annotation array. |
| `LumeshotAnnotate/Rendering/AnnotationRenderer` | A shared CoreGraphics draw routine serves the canvas and final flattened image. |
| `LumeshotAnnotate/Editor/EditorModel` | Main-actor pointer dispatch for selection and drawing; publishes annotations, selection, and undo/redo availability. |
| `LumeshotApp/EditorWindowController` + `EditorSettings.annotateBeforeShare` gate | Opt-in "Annotate Before Sharing" menu toggle (default off) gates `CaptureCoordinator.deliver`; when on, `EditorWindowController.present` opens the editor between capture and the existing save→clipboard→upload chain — Save/Upload flatten the document and continue delivery, Copy writes the image to the clipboard, and Cancel (or closing the window) discards |

**Deferred:** rotation, curved line/arrow segments, additional arrowhead styles, and shadows. Crop, text, effects, step badges, and explicit Copy / Save / Upload actions shipped in M3b.
