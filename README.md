# Lumeshot

A Swift-native screenshot, annotation, upload, and screen-recording tool for macOS (Apple Silicon, macOS 15+), reimplementing the [ShareX](https://github.com/ShareX/ShareX) workflow as a first-class Mac citizen — menu-bar resident, ScreenCaptureKit capture, `.sxcu` custom-uploader compatibility.

**Status:** v1 feature-complete — capture, a full annotation editor, screen recording, five uploader backends, a dedicated Preferences window, and an ad-hoc `.dmg` release pipeline. See **[docs/ROADMAP.md](docs/ROADMAP.md)** for the detailed status, pending manual smokes, and what's next. Design: `docs/superpowers/specs/2026-07-10-sharex-mac-design.md` · Build: `scripts/remote.sh build` (see the spec for the SSH dev loop).

## Features

**Capture** (menu-bar resident, hotkey-driven)
- Fullscreen (all displays), Region (drag-to-select), Window (hover-to-highlight)
- After-capture pipeline: save to disk → clipboard → optional upload → history (local-first: disk write always precedes upload)
- Permission gating for the TCC Screen Recording grant on first run

**Editor** (opt-in via "Annotate Before Sharing")
- Vector tools: rectangle, ellipse, line, arrow, freehand
- Redaction & callouts: blur, pixelate, highlighter, text, step-number badges
- Non-destructive crop; select/move/resize; unlimited* undo/redo (*bounded to the last 50 edits)
- Non-destructive document (base image + ordered shape list) flattened via CoreGraphics on Copy / Save / Upload

**Screen recording**
- ScreenCaptureKit `.mp4` recording — region, window, or display
- On-demand "Export as GIF…" from the History window (the mp4 is always kept)
- Optional system-audio capture; H.264 / HEVC

**Uploaders**
- **Custom `.sxcu`** — ShareX JSON configs; request templating + regex/JSON response-URL extraction
- **Imgur** — anonymous upload (share URL + deletion URL)
- **S3-compatible** — hand-rolled SigV4 (AWS / Cloudflare R2 / MinIO / Backblaze B2); path + virtual-host addressing; optional ACL; custom result-URL domain
- **SFTP** — password or private-key auth (Citadel / SwiftNIO-SSH)
- **FTP / FTPS** — libcurl

**Preferences window** (⌘,)
- Tabbed Settings: General · Capture · Hotkeys · Uploads · Recording
- Live hotkey recorder (click, press a combo — re-registers instantly, no relaunch)
- Destination management (add/remove/select S3/SFTP/FTP/Imgur, import `.sxcu`) folded into the Uploads tab

**History browser**
- Thumbnails, search by filename/URL; Copy URL, Open, Reveal in Finder, Delete (local + remote cleanup)

**Distribution**
- Ad-hoc-signed `.dmg` built by a `v*`-tag-triggered GitHub Actions release (no Apple Developer account yet — see `docs/RELEASING.md`)

## Security

Secrets (API keys, S3 keys, SFTP/FTP passwords and private keys, `.sxcu` header/param secrets) are stored **only in the login Keychain** (`org.sharexmac.app`), never in `settings.json`.

## Not affiliated

Not affiliated with the ShareX project; built with deep respect for it. The ShareX codebase serves as the behavioral specification for this reimplementation.

## License

[GPL-3.0](LICENSE), matching upstream ShareX.
