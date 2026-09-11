# M5b smoke checklist (release dmg + robustness/UI polish)

B1 (atomic Keychain store), B2 (FTP stall abort) and B3 (recorder re-entrancy
guard) are covered by their LumeshotCoreTests/LumeshotRecordTests unit tests plus
the live SFTP/FTP tests in `docs/smoke-m5a.md` — not re-verified here.

- [x] **dmg builds, mounts, and drag-installs (R1)** — verified headlessly on
      2026-09-09: `swift build -c release && scripts/bundle.sh && VERSION=… scripts/dmg.sh`
      produced the dmg, `hdiutil attach` mounted it at `/Volumes/Lumeshot` showing
      `Lumeshot.app` beside an `Applications -> /Applications` symlink, and copying
      the app off the volume left a bundle that still passed
      `codesign --verify --deep --strict` and ran. The Finder window's *appearance*
      is the only part a human still sees, and v0.1.15/v0.1.17 were installed from
      a dmg by hand.
- [ ] **GIF-export shows a spinner (P2):** History → export an mp4 as GIF. While
      `isExporting` is true (Cancel/Export both disabled), confirm a spinner +
      "Exporting…" text is visible next to the buttons, not just two disabled
      buttons that look frozen.
- [x] **Elapsed timer no longer flashes 0:00 (P1)** — the menu title is derived
      from the recording's start date rather than a counter, so a rebuild
      mid-recording re-renders the same time. Pinned by
      `RecordingElapsedTests.rebuildingTheMenuMidRecordingKeepsTheElapsedTime`.
- [x] **Inspector reflects the selected annotation (P3)** — pinned by
      `EditorModelTests.selectingEachAnnotationInTurnSyncsThatOnesInspectorValue`,
      which draws a blur, a pixelate and a text annotation with three different
      values, drifts every inspector control away from all of them, then selects
      each in turn. What is left for a human is that the matching *control*
      (Slider/Slider/Stepper) appears in the left tool rail, under its tool.
- [x] **Release workflow YAML sanity** — `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))"`
      exits 0. (The workflow only fully runs on a real `v*` tag push; v0.1.15–v0.1.17
      exercised it for real.)

M5a SFTP/FTP smoke: see `docs/smoke-m5a.md`. M1 capture smoke: see `docs/smoke-m1.md`. M2a upload
smoke: see `docs/smoke-m2a.md`. M4 recording smoke: see `docs/smoke-m4.md`.
