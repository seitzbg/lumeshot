# Open bug: region capture (⌥⇧4) silently produces nothing on macOS 26

_Filed 2026-09-06. Reproduced on BSMBP2 (MacBook Pro, macOS 26.6.2, built-in
Liquid Retina XDR, 1728×1117 pt @2x). Not reproducible on the macOS 15 dev Mac._

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

1. `ls -lt ~/Pictures/ShareX | head` right after an attempt.
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
