# Lumeshot

A Swift-native screenshot, annotation, upload, and screen-recording tool for macOS (Apple Silicon, macOS 15+). Lumeshot lives in the menu bar, captures with ScreenCaptureKit, and supports `.sxcu` custom uploaders.

**Status:** v1 feature-complete — capture, a full annotation editor, screen recording, five uploader backends, a dedicated Preferences window, and a Developer ID signed + notarized `.dmg` release pipeline. See **[docs/ROADMAP.md](docs/ROADMAP.md)** for the detailed status, pending manual smokes, and what's next. Design: `docs/superpowers/specs/2026-07-10-lumeshot-design.md` · Local build: `swift build` (see [local development](docs/local-development.md)).

## Screenshots

Shown in dark appearance. Settings follows your Mac’s light or dark theme.

<img src="docs/images/settings-general.png" alt="Lumeshot General settings in dark appearance, with sidebar navigation and grouped capture controls" width="820">

<img src="docs/images/settings-uploads-dark.png" alt="Lumeshot Uploads settings in dark appearance, with multiple uploaders and an active uploader selection" width="820">

Uploader configuration uses grouped fields and a dedicated action bar.

<img src="docs/images/settings-uploader.png" alt="Picsur uploader dialog in dark appearance with connection settings and sharing options" width="540">

## Features

**Capture** (menu-bar resident, hotkey-driven)
- Fullscreen (all displays), Region (drag-to-select), Window (hover-to-highlight)
- After-capture pipeline: save to disk → copy image → optional upload → history. Upload success copies the uploaded URL, skipping replacement when it detects a newer copy; upload failure leaves the current clipboard intact. Preservation across apps is best effort.
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
- **Custom `.sxcu`** — JSON uploader configs; request templating + regex/JSON response-URL extraction
- **Imgur** — anonymous upload (share URL + deletion URL)
- **Picsur** — self-hosted image host; API-key auth, choice of serving format and direct-image vs viewer-page links
- **S3-compatible** — hand-rolled SigV4 (AWS / Cloudflare R2 / MinIO / Backblaze B2); path + virtual-host addressing; optional ACL; custom result-URL domain
- **SFTP** — password or private-key auth (Citadel / SwiftNIO-SSH); host key pinned on first connection and verified thereafter
- **FTP / FTPS** — libcurl

**Preferences window** (⌘,)
- Appears in the Dock and app switcher while open; closing Settings returns Lumeshot to menu-bar-only mode.
- Sidebar Settings: General · Capture · Shortcuts · Uploads · Recording, following the system’s light/dark appearance
- Live hotkey recorder (click, press a combo — re-registers instantly, no relaunch)
- Configure multiple uploaders (S3/SFTP/FTP/Imgur/Picsur or imported `.sxcu`), then choose one **Active uploader** on the Uploads page. Adding another uploader preserves your selection.

**History browser**
- Thumbnails, search by filename/URL; Copy URL, Open, Reveal in Finder, Delete (removes the history row and, when the uploader gave one, the remote copy; the local file is left on disk)

**Distribution**
- Developer ID signed, notarized and stapled `.dmg`, built by a `v*`-tag-triggered GitHub Actions release; hardened runtime with no entitlement exceptions. Signing is opt-in on secret presence, so a fork without credentials still publishes an (ad-hoc) dmg. One-time setup: `scripts/setup-developer-id.sh` — see `docs/RELEASING.md`

## Security

Secrets (API keys, Picsur API keys, S3 keys, SFTP/FTP passwords and private keys) are stored **only in the login Keychain** (`org.lumeshot.app`), never in `settings.json`.

For imported `.sxcu` custom uploaders the guarantee is narrower, because the format lets a credential sit anywhere. Two surfaces are protected unconditionally — the JSON body template, and a `RequestURL` carrying a query string or user-info, both stored in full. Headers, arguments and query parameters are matched against a key-name heuristic (`authorization`, `token`, `api_key`, `signature`, …). That heuristic is deliberately over-eager, but a secret under a genuinely innocuous key can still reach `settings.json` — treat an untrusted `.sxcu` accordingly.

## License

[GPL-3.0](LICENSE).
