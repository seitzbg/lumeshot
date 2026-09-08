# Changelog

Release notes describe the changes in each published version.

## Unreleased

- Lumeshot now updates itself. It checks daily and on demand, then downloads, verifies and
  installs the update — no more downloading a dmg and dragging it to Applications.
- Testing an uploader now sends what that destination will actually carry — a short video
  to uploaders that accept video, a generated image to image-only ones. The Test sheet says
  which before it runs.
- Upload failures now record the underlying reason in `~/Library/Logs/Lumeshot.log`,
  including failures from the uploader Test sheet.

## Releases

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
