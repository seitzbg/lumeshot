# Region capture (⌥⇧4) silently produces nothing: optional callback skips persistence

_Filed 2026-09-06. Reproduced on BSMBP2 (MacBook Pro, macOS 26.6.2, built-in
Liquid Retina XDR, 1728×1117 pt @2x). Not reproducible on the macOS 15 dev Mac._

## Root cause found locally (2026-09-06)

`CaptureCoordinator.deliver()` calls:

```swift
onOutcome?(finishPersist(image: image, ...))
```

Swift optional chaining does **not evaluate the arguments** when the optional
closure is nil. Region and window capture call `deliver` without `onOutcome`,
so `finishPersist` never runs: no encoding, file, notification, upload, or
delivery/failure log. Fullscreen supplies an outcome closure to count persisted
files, so that path works. The editor's Save and Upload branches contain the
same mistake. This is a control-flow bug independent of macOS version; the
earlier OS-specific observation did not establish the cause.

The local log's region attempts at 02:17:58 and 02:18:41 produced no file in
the then-configured capture folder (the latest file was 02:06:21), consistent with the skipped
persistence call. The crop and encoder do not need a workaround.

Fix: evaluate `finishPersist` into a local result unconditionally, then pass
that result to `onOutcome?`. Apply to passthrough, editor Save, and editor Upload.

Regression coverage in `Tests/LumeshotAppTests/CaptureCoordinatorTests.swift`
feeds a cropped image through the actual coordinator for all three routes,
with and without an outcome callback. It verifies exactly one PNG with the
crop's dimensions, callback results, and explicit Save overriding disabled
automatic saving. It uses temporary settings/output and simulated clipboard/notification effects,
with network upload disabled.

Validation on macOS 26.6.2: before the fix, all three cases without a callback
failed with a missing PNG; the three cases with a callback passed. After the
fix, all six cases passed, along with crop geometry, PNG encoder, and pipeline
tests (16 tests total). After the clean-break rebrand, the full suite also
passed (384 tests in 78 suites). Release compilation passed. The GUI hotkey smoke
is still pending; see `docs/local-development.md` for the local test command,
renamed data paths, and smoke steps.

## Original investigation

The notes below preserve the evidence and the initial hypothesis before the
optional-callback short circuit was identified. Example paths now use the
current Lumeshot defaults.

## Symptom

⌥⇧4 shows the overlay, accepts a drag, and then nothing happens: no capture
file, no notification, no error. Fullscreen (⌥⇧3) on the same machine and
settings works perfectly, including upload to Picsur.

## What the log proves

From v0.1.4 (per-event region logging), a representative attempt:

```
captureRegion invoked; preflight=true
captureAllDisplays returned 1 display(s) for region overlay
  display 1: screenFrame={{0,0},{1728,1117}} scale=2.0 image=3456x2234
Region overlay: mouseDown at {527, 186}
Region overlay: mouseUp, selection {{527,186},{219,225}}
Region selection {…} → crop={{1054,372},{440,452}}
(nothing further)
```

So, established:
- Geometry is consistent (scale 2.0, 1728×1117 pt ↔ 3456×2234 px).
- Mouse events reach the overlay; the drag is a real, in-bounds selection.
- `CaptureGeometry.pixelCropRect` returns a valid, non-empty crop.
- The process does **not** crash (`pgrep` still shows it; no new `.ips`).
- `annotateBeforeShare` is **false**, so `deliver()` takes the passthrough
  branch to `finishPersist`, which logs `Capture delivered` or `Capture
  failed` unconditionally — yet neither appears.

## The gap

`RegionOverlay.finish()` logs the crop, then:

```swift
guard let cropped = display.image.cropping(to: crop) else { … onComplete(nil); return }
onComplete(cropped)          // → CaptureCoordinator closure → deliver(image:) → finishPersist
```

Every branch from here logs something, and none does. The failure is in
`cropping(to:)` → `ImageEncoder.png(from:)` → `AfterCapturePipeline.process`
on the *cropped* image specifically (fullscreen delivers the full display
image through the identical path and works), or in reaching that closure at
all.

## Next step (cheap, decisive)

1. `ls -lt ~/Pictures/Lumeshot | head` right after an attempt.
   - A file dated to the attempt → `finishPersist` ran; the bug is only that
     the region path isn't logging. Narrow.
   - No new file → the cropped image dies in crop→encode→write. Real bug.
2. Add a log line on each side of `cropping(to:)` and `ImageEncoder.png` in
   `RegionOverlay.finish()` / `CaptureCoordinator.finishPersist`, rebuild,
   click once. That pins the exact call.

Do this **on the Mac** — it is a GUI-event, macOS-26-only bug, and the
edit→build→click→read-log loop is seconds locally versus minutes over ssh.

## Relevant files

- `Sources/LumeshotApp/RegionOverlay.swift` — `finish()` (crop + `onComplete`)
- `Sources/LumeshotApp/CaptureCoordinator.swift` — `captureRegion()`, `deliver()`, `finishPersist()`
- `Sources/LumeshotCapture/CaptureGeometry.swift` — `pixelCropRect` (verified correct)
- `Sources/LumeshotCapture/ImageEncoder.swift` — `png(from:)`

## Verified working on macOS 26 (context)

Signing/notarization/Gatekeeper, launch + menu bar, fullscreen capture,
notifications (banner + click-to-reveal), Picsur upload end-to-end, paste in
Preferences, destination editing. Region capture is the sole holdout.
