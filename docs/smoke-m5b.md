# M5b manual smoke checklist (release dmg + robustness/UI polish)

Run on the Mac after `scripts/remote.sh run` (for the UI items) and via `scripts/remote.sh ssh`
(for the dmg packaging item). Diagnostics: `~/Library/Logs/ShareX-Mac.log`. B1 (atomic Keychain
store), B2 (FTP stall abort), and B3 (recorder re-entrancy guard) are covered by their
SXCoreTests/SXRecordTests unit tests plus the existing SFTP/FTP live-upload smoke in
`docs/smoke-m5a.md` — not re-verified here.

- [ ] **dmg builds, mounts, and drag-installs (R1):** `scripts/remote.sh ssh 'swift build -c
      release && scripts/bundle.sh && VERSION=0.1.0 scripts/dmg.sh'`; confirm
      `dist/ShareX-for-Mac-0.1.0.dmg` is created. Double-click it in Finder (or `hdiutil attach`);
      confirm a Finder window opens showing "ShareX for Mac.app" and an "Applications" symlink;
      drag the app onto Applications and launch it from there.
- [ ] **Elapsed timer no longer flashes 0:00 (P1):** Start a recording, wait a few seconds, then
      trigger any menu rebuild mid-recording (e.g. toggle **System Audio**, which calls
      `rebuildMenu()`). Confirm the elapsed menu item's time does NOT reset to `0:00` even
      momentarily — it keeps counting from where it was.
- [ ] **GIF-export shows a spinner (P2):** History → export an mp4 as GIF. While `isExporting` is
      true (Cancel/Export both disabled), confirm a spinner + "Exporting…" text is visible next to
      the buttons, not just two disabled buttons that look frozen.
- [ ] **Inspector reflects the selected annotation (P3):** In the editor, draw a blur, a pixelate,
      and a text annotation, each with a distinct blur radius / pixel scale / font size. Switch to
      the **Select** tool and click each one in turn; confirm the toolbar inspector shows the
      matching control (Slider/Slider/Stepper, not empty) pre-filled with THAT annotation's real
      value (not whatever was last set while drawing). Adjust the control and release; confirm it
      updates that specific annotation only.
- [ ] **Release workflow YAML sanity:** `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))"`
      exits 0. (The workflow itself only fully runs on a real `v*` tag push — not exercised here.)

M5a SFTP/FTP smoke: see `docs/smoke-m5a.md`. M1 capture smoke: see `docs/smoke-m1.md`. M2a upload
smoke: see `docs/smoke-m2a.md`. M4 recording smoke: see `docs/smoke-m4.md`.
