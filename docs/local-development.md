# Local Mac development

From the repository root with Xcode selected (for Command Line Tools alone,
replace `swift test` with the required command in the next section):

```sh
swift build
swift test
swift build -c release
VERSION=0.1.5 scripts/bundle.sh
open dist/Lumeshot.app
```

Quit any running copy of Lumeshot before opening the new bundle so it can
register the capture hotkeys. The bundle script uses the local `lumeshot-dev`
signing identity when configured; otherwise it signs ad hoc. Ad-hoc rebuilds
can require a new Screen Recording grant.

## Command Line Tools test runner

On the macOS 26.6.2 local development machine, the installed Command Line Tools
need explicit search paths for the Testing framework and its runtime library.
No Xcode installation or repository dependency change is required:

```sh
swift test --disable-xctest \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath \
  -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath \
  -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Add `--filter CaptureCoordinatorTests` for the region delivery regression.
It uses synthetic cropped images and temporary settings/output, so it does
not need Screen Recording permission or an upload destination.

## App identity and data

- Bundle ID and Keychain service: `org.lumeshot.app`
- Settings and history: `~/Library/Application Support/Lumeshot/`
- Default captures: `~/Pictures/Lumeshot/`
- Diagnostics: `~/Library/Logs/Lumeshot.log` (plus one rotated `.1` file)
- Development signing: `lumeshot-dev`, `lumeshot-signing.keychain-db`,
  and `~/.config/lumeshot/signing.pw`

The rebrand is a clean break. Earlier application data is left untouched and
is not imported automatically. Configure upload destinations and credentials
again, and grant Screen Recording and notifications to the new app identity.
Existing `.sxcu` files can still be imported.

## Region capture smoke

1. Launch the new bundle and grant Screen Recording permission.
2. With annotation disabled, press **⌥⇧4**, drag a region, and release.
3. Verify a new PNG in the capture folder and a `Capture delivered` entry in
   `~/Library/Logs/Lumeshot.log`.
4. Repeat with **⌥⇧5** for window capture, then enable annotation and verify
   the editor's Save action. Upload requires a configured destination.

These GUI checks remain separate from the automated delivery regression.
