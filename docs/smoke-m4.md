# M4 manual smoke checklist (recording)

Run on the Mac after `scripts/remote.sh run`. Diagnostics: `~/Library/Logs/ShareX-Mac.log`
(same log the M1/M2a checklists use — tail it while exercising this list). All boxes must
pass to call M4 done; Task 15 (optional ffmpeg palettegen branch) is skippable and does not
block this checklist.

- [ ] **Region recording start→stop:** Menu bar → Start Recording ▸ Region (or ⌥⇧6). The
      region overlay appears identically to a region *capture*; drag a selection. Confirm the
      menu-bar icon switches to the red stop-circle and an elapsed-time label starts counting
      up next to it.
  - [ ] **Task 4 checkpoint — `addRecordingOutput` runtime check:** this is the first time
        `SCStream.startCapture()` runs with *only* a recording output attached (no
        `SCStreamOutput`) — never runtime-verified during Task 4 (build-only + deferred to this
        checklist per its report). If `startCapture` throws/errors here needing a stream
        output, the fix is to add a minimal no-op `SCStreamOutput` on a background
        `DispatchQueue` in `Sources/SXRecord/ScreenRecorder.swift` before calling
        `startCapture()` — do not silently work around it elsewhere.
- [ ] **Stop via menu:** Click the menu-bar icon → **Stop Recording**. Confirm the icon
      returns to the camera glyph, the elapsed label clears, and (if **Save to disk** is on) an
      `.mp4` lands in `~/Pictures/ShareX` with a filename matching the configured template.
- [ ] **Stop via hotkey (record hotkey toggle):** Start a region recording (⌥⇧6), then press
      ⌥⇧6 again to stop. Confirm it stops (not a second recording starting).
- [ ] **Window recording:** Start Recording ▸ Window; the picker overlay behaves like window
      *capture* (hover-highlight, click to pick). Record a few seconds of a window with visible
      motion (e.g. scroll some text); confirm the output mp4 is cropped to that window's
      content only.
- [ ] **Display recording:** Start Recording ▸ Display with the mouse over a specific monitor
      (multi-display setups only, otherwise this is equivalent to the single display); confirm
      the display *under the mouse* is the one recorded.
- [ ] **System Audio toggle:** Menu bar → System Audio (checkbox toggles); confirm the
      checkmark persists across a menu reopen and across app relaunch (`settings.json`'s
      `recording.systemAudio`). Record with it on while audio is playing; confirm the mp4 has
      an audio track. Confirm no microphone permission prompt ever appears (system audio rides
      the existing Screen Recording TCC grant — no new entitlement was added in Task 14).
- [ ] **Codec setting:** Hand-edit `~/Library/Application Support/ShareX-Mac/settings.json`'s
      `recording.videoCodec` to `"hevc"`, relaunch, record a clip; confirm the output plays
      (HEVC) and `ffprobe`/QuickTime report the expected codec. Set back to `"h264"` (the
      default) afterward.
- [ ] **Local-first / upload-after-capture path:** With an active upload destination and
      **Upload After Capture** on, record a clip; confirm the mp4 is written to disk **before**
      the URL lands on the clipboard (the file exists even if you kill network mid-upload), and
      the History row shows the destination + URL once the upload completes.
- [ ] **Upload failure:** Temporarily point the active destination at an unreachable URL (or
      disconnect network), record a clip; confirm the mp4 + its History row remain
      (`uploadFailed` shown in the row), and an "Upload failed… Local file kept" notification
      appears.
- [ ] **History video row:** Open History (menu → History…). Confirm mp4 rows show a film-icon
      placeholder (not a broken image), while PNG rows still show real thumbnails.
- [ ] **Export as GIF… from History:** On an mp4 row, click the film-stack button. The
      fps/max-width sheet appears pre-filled from `recording.gifFPS`/`gifMaxWidth` (defaults
      15fps / 640px). Click Export; confirm a new `.gif` row appears in History next to the
      source mp4 row (the mp4 row is untouched), and the `.gif` file plays as an animated loop
      in Finder/Preview.
- [ ] **GIF export failure + Task 13 checkpoint — alert race:** Point "Export as GIF…" at a
      corrupt/zero-byte "mp4" (e.g. rename an empty file to `.mp4` in the captures folder, then
      re-open History so it appears as a row) and attempt export; confirm the "Export Failed"
      alert **actually presents** (fail-loud), not just that the sheet silently closes. This is
      a real risk, not a formality: `HistoryModel.exportGif` (`Sources/SXApp/HistoryView.swift`)
      sets `exportError` and then `exportingEntry = nil` back-to-back on failure, which dismisses
      the `.sheet(item: $model.exportingEntry)` and asks SwiftUI to present the
      `.alert(isPresented: .constant(model.exportError != nil), ...)` in the same update cycle —
      a known SwiftUI sheet-dismiss/alert-present race that can silently eat the alert. If the
      alert doesn't appear, don't paper over it in the checklist; it needs a real fix (e.g.
      delay clearing `exportingEntry` a tick, or drive the alert from the sheet's own view
      instead of the parent).
- [ ] **Multiple recordings / re-entrancy:** With a recording in progress, click Start
      Recording ▸ Region again from the menu; confirm it's a no-op (guarded by
      `isRecording`/`isPresentingOverlay`) rather than starting a second concurrent stream.
- [ ] **Cancel mid-setup:** Start Recording ▸ Region, then press Escape on the overlay before
      dragging a selection; confirm no recording starts and the icon stays idle.
- [ ] **Elapsed-time display accuracy:** Record for ~65 seconds; confirm the menu-bar label and
      the disabled elapsed menu item both show `1:05`-ish (not reset, not frozen) and that the
      menu didn't visibly flicker/rebuild every second (only the label text changes).

M1 capture smoke: see `docs/smoke-m1.md`. M2a upload smoke: see `docs/smoke-m2a.md`.
