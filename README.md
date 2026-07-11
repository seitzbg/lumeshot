# sharex-mac

A Swift-native screenshot, annotation, upload, and screen-recording tool for macOS (Apple Silicon, macOS 15+), reimplementing the [ShareX](https://github.com/ShareX/ShareX) workflow as a first-class Mac citizen — menu-bar resident, ScreenCaptureKit capture, `.sxcu` custom-uploader compatibility.

**Status:** M2b — capture and upload complete. Uploaders: custom .sxcu, Imgur (anonymous), and S3-compatible (AWS/R2/MinIO/B2). Destinations searchable and Keychain-managed. History browser with search and remote cleanup. Design: docs/superpowers/specs/2026-07-10-sharex-mac-design.md · Build: `scripts/remote.sh build` (see spec §4 for the SSH dev loop).

## Features

**Capture modes** (menu-bar resident, hotkey-driven)
- Fullscreen — all displays, one PNG each
- Region — drag-to-select, saved PNG + clipboard copy
- Window — hover-to-highlight, click to capture, saved PNG + clipboard copy
- Permission gating: System Settings + relaunch on first run (TCC Screen Recording grant)

**Uploaders**
- **Custom .sxcu**: Parses ShareX JSON configs; request templating (parameters, headers, body); regex-based response URL extraction; secrets → Keychain
- **Imgur**: Anonymous upload via Client-ID; returns the share URL and a deletion URL (OAuth/authenticated albums deferred)
- **S3-compatible**: Hand-rolled SigV4 signing (CryptoKit HMAC-SHA256) · supports AWS, Cloudflare R2, MinIO, Backblaze B2 · path-based and virtual-host addressing · optional ACL header · custom result-URL domain (CDN/reverse-proxy rewriting)

**Destination management**
- Add/remove/select destinations without editing JSON
- Import `.sxcu` custom uploader configs
- Active destination persisted in settings; secrets stored in login Keychain (`org.sharexmac.app`), never in `settings.json`

**History browser**
- List with thumbnails of all captures
- Search by filename or URL
- Actions: Copy URL, Open in browser, Reveal in Finder, Delete (local + remote cleanup via deletion URL)
- SQLite-backed (`~/Library/Application Support/ShareX-Mac/history.sqlite`)

**Hotkeys** (⌥⇧3/4/5 by default; ⌘⇧ reserved for system)
- Fullscreen, Region, Window capture

## After-capture workflow

1. Capture via hotkey or menu
2. Automatic save to `~/Pictures/ShareX-Mac/` with `%y-%mo-%d_%h-%mi-%s` naming
3. Clipboard copy (auto on capture; custom uploader result URL on success)
4. Upload to active destination (if configured, non-blocking)
5. History recorded (local + remote URL when available)

Not affiliated with the ShareX project; built with deep respect for it. The ShareX codebase serves as the behavioral specification for this reimplementation.

## License

[GPL-3.0](LICENSE), matching upstream ShareX.
