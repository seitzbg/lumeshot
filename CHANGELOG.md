# Changelog

Release notes describe the changes in each published version.

## Unreleased

- SFTP now fails closed when two first-time uploads to the same destination race and the second server presents a different host key than the one just pinned, instead of silently trusting it.
- A failed screen-recording upload no longer writes the raw server response to the log, matching the redaction the still-image path already had — an error body can echo an API key or deletion token.
- Editing General/Capture/Recording/Shortcut preferences no longer overwrites an SSH host key learned from a connection at the same moment.
- The editor keeps its Cancel/Copy/Save/Upload buttons on screen at the smallest window size: the text, blur and pixelate controls now live in the left tool rail rather than crowding the top bar.
- Moving a crop against an image edge and back no longer permanently shrinks it.
- A settings file that exists but cannot be read is no longer treated as an empty configuration: preference edits and SSH host-key checks now abort instead of overwriting your saved uploaders with defaults or trusting a host key as if none were pinned.
- A failed SFTP upload no longer writes the server's status message to the log (it can echo a remote path or a token); the log keeps the SSH status code and the error type.
- A custom uploader whose server returns a non-web value — a `file:` URL, an app scheme, or an error page — is treated as a failed upload instead of being copied to the clipboard, and History and notifications only open `http(s)` links.
- A custom uploader response that leaves the image id empty is treated as a failed upload, instead of copying a broken link such as `https://host/i/.png`.
- Resizing an annotation by dragging a handle past its opposite edge and back no longer drags the anchored edge with it, so a crop keeps its intended size.
- Increasing a text annotation's font size no longer pushes the text out of its box and drops it from the exported image; the box grows to fit the larger text.
- Lumeshot no longer advertises itself as an opener for MP4 and GIF files, which only produced an import error; opening a file still imports `.sxcu` uploader configs.

## Releases

- [v0.1.22](docs/releases/v0.1.22.md) — The editor now sizes its window to the capture (1:1 when it fits, scaled to fit the screen when it doesn't), instead of reusing a remembered size.
- [v0.1.21](docs/releases/v0.1.21.md) — The annotation editor opens at a larger, screen-capped default and remembers the size and position you set.
- [v0.1.20](docs/releases/v0.1.20.md) — The annotation editor's tools now read as a native macOS sidebar: grouped sections, translucent material, and a Finder-style selected row.
- [v0.1.19](docs/releases/v0.1.19.md) — The annotation editor's tools now sit in a labelled left-hand rail, so each tool's function is clear at a glance.
- [v0.1.18](docs/releases/v0.1.18.md) — The editor's Cancel/Copy/Save/Upload buttons are readable again, and an SFTP RSA key now fails with a clear reason.
- [v0.1.17](docs/releases/v0.1.17.md) — Clicking a notification no longer opens Settings on top of the file or link it just opened.
- [v0.1.16](docs/releases/v0.1.16.md) — Identical to v0.1.15; published so the automatic updater has a newer release to install.
- [v0.1.15](docs/releases/v0.1.15.md) — Automatic updates, and twelve code-review fixes covering lost uploads, credential edits, crops and redactions.
- [v0.1.14](docs/releases/v0.1.14.md) — Guard rails for upload destinations: image-only hosts, untested uploaders, and logged recording failures.
- [v0.1.13](docs/releases/v0.1.13.md) — Fix the Download button in the update alert doing nothing.
- [v0.1.12](docs/releases/v0.1.12.md) — Separate upload destination for screen recordings, and an uncut menu-bar timer.
- [v0.1.11](docs/releases/v0.1.11.md) — Download an available update, and clear an upload's status when its History row is removed.
- [v0.1.10](docs/releases/v0.1.10.md) — Identical to v0.1.9; published to exercise the update check.
- [v0.1.9](docs/releases/v0.1.9.md) — Stacked blur/pixelate, editor fixes, and a Check for Updates command.
- [v0.1.8](docs/releases/v0.1.8.md) — Align assigned and unset shortcut controls.
- [v0.1.7](docs/releases/v0.1.7.md) — About and open source credits, roomier uploader selection, upload status and testing, History improvements, retry, and authenticated remote deletion.
- [v0.1.6](docs/releases/v0.1.6.md)
- [v0.1.5](docs/releases/v0.1.5.md)
- [v0.1.4](docs/releases/v0.1.4.md)
- [v0.1.3](docs/releases/v0.1.3.md)
- [v0.1.2](docs/releases/v0.1.2.md)
- [v0.1.1](docs/releases/v0.1.1.md)
- [v0.1.0](docs/releases/v0.1.0.md)

Download signed releases from [GitHub Releases](https://github.com/seitzbg/lumeshot/releases).
