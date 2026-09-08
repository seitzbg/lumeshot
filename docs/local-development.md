# Local Mac development

From the repository root with Xcode selected (for Command Line Tools alone,
replace `swift test` with the required command in the next section):

```sh
swift build
swift test
swift build -c release
BUNDLE_OUTPUT=dist/test/Lumeshot.app VERSION="$(git describe --tags --abbrev=0 | sed 's/^v//')" scripts/bundle.sh
open dist/test/Lumeshot.app
```

`VERSION` only stamps `Info.plist` for this throwaway bundle, so it is read from
the latest tag rather than written out — nothing here ships, and a literal version
would need bumping every release.

Quit any running copy of Lumeshot before opening the new bundle so it can
register the capture hotkeys. The bundle script uses the local `lumeshot-dev`
signing identity when configured; otherwise it signs ad hoc. Ad-hoc rebuilds
can require a new Screen Recording grant.

`scripts/bundle.sh` finishes by running the bundled binary with `--version`,
which prints the stamped version and channel and exits before the app starts:

```sh
dist/test/Lumeshot.app/Contents/MacOS/LumeshotApp --version
# Lumeshot 0.1.14 (development)
```

That is a launch smoke test, not a formality. `codesign --verify` passes on a
bundle that cannot start, so packaging checks dynamic-library resolution by
actually executing it. `--version` touches no capture API, so unlike opening the
app it cannot re-point the installed copy's Screen Recording grant.

Local builds sign with `Resources/Lumeshot-dev.entitlements`, which disables
library validation; release builds use the empty `Resources/Lumeshot.entitlements`.
The hardened runtime requires the app and Sparkle.framework to share a Team ID,
and `codesign` only derives one from an Apple-issued certificate — both an
ad-hoc signature and the self-signed `lumeshot-dev` identity report
`TeamIdentifier=not set`, which does not match itself. Without that one
exception a local bundle cannot load Sparkle at all. `scripts/bundle.sh` picks
the file from `DEVELOPER_ID_SIGNING`, so nothing shipped carries it.

Use one consistent location for local test apps: `dist/test/Lumeshot.app`.
Update that bundle for each iteration instead of creating another named test
directory. Quit the running test copy before packaging, then reopen the same path:

```sh
swift build -c release
BUNDLE_OUTPUT=dist/test/Lumeshot.app VERSION="$(git describe --tags --abbrev=0 | sed 's/^v//')" scripts/bundle.sh
open dist/test/Lumeshot.app
```

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

## Updating open source acknowledgments

After changing package versions, run `swift package resolve` followed by
`python3 scripts/generate-credits.py` and commit the updated
`Sources/LumeshotApp/Resources/OpenSourceCredits.json`. The generator reads the
resolved checkouts' license and notice files; the About window displays these
offline. `scripts/bundle.sh` includes the same resource in release apps.
The credits test checks coverage and versions against `Package.resolved`.
System-library and vendored-component notices are maintained in `scripts/licenses`.

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
