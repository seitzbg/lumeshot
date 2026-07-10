# sharex-mac

A Swift-native screenshot, annotation, upload, and screen-recording tool for macOS (Apple Silicon, macOS 15+), reimplementing the [ShareX](https://github.com/ShareX/ShareX) workflow as a first-class Mac citizen — menu-bar resident, ScreenCaptureKit capture, `.sxcu` custom-uploader compatibility.

**Status:** M1 (capture core) — menu-bar app with fullscreen/region/window capture, global hotkeys, clipboard + disk + notifications. Design: [`docs/superpowers/specs/2026-07-10-sharex-mac-design.md`](docs/superpowers/specs/2026-07-10-sharex-mac-design.md) · Build: `scripts/remote.sh build` (see spec §4 for the SSH dev loop).

Not affiliated with the ShareX project; built with deep respect for it. The ShareX codebase serves as the behavioral specification for this reimplementation.

## License

[GPL-3.0](LICENSE), matching upstream ShareX.
