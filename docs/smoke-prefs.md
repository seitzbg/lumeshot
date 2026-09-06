# Preferences window manual smoke checklist

Run on the Mac after `scripts/remote.sh run`. Diagnostics: `~/Library/Logs/Lumeshot.log`.
Covers the tabbed Preferences window (Tasks 1–5, 7) end to end; Task 6's hotkey
formatting/mapping is covered by `Tests/LumeshotCoreTests/HotkeyFormattingTests.swift`, not
re-verified here.

- [ ] **Window opens and reuses (Task 1):** Status-bar menu → **Settings…** (confirm the ⌘,
      keyEquivalent also opens it while the status-bar menu is open). A window titled
      "Lumeshot Settings" appears with 5 tabs: General, Capture, Hotkeys, Uploads, Recording.
      Close it and reopen via the menu; confirm it's the same window (position/selected tab
      persist within the app session), not a second window stacking on top.
- [ ] **App switcher:** Open Settings and confirm Lumeshot appears in the Dock and
      ⌘Tab (and AltTab, if installed). Switch away and back. Minimize Settings,
      then click Lumeshot in the Dock to restore it. Hide with ⌘H and switch back.
      Close Settings with the red button or ⌘W: the Dock entry disappears while
      the menu-bar icon and capture hotkeys remain. Reopen Settings and repeat.
- [ ] **General tab persists + live-applies (Task 2):** Toggle each of the 3 switches (Save
      to Disk, Show Notification, Annotate Before Sharing). Confirm
      `settings.json` reflects each change immediately and the "Annotate Before Sharing"
      status-bar checkmark follows the last one.
- [ ] **Capture tab (Task 3):** Confirm the Save Folder field shows `~/Pictures/Lumeshot`
      abbreviated with `~`. Click **Choose…**, pick a new folder; capture (⌥⇧3) and confirm
      the file lands there. Edit the filename template; confirm the next capture's name
      matches it.
- [ ] **Recording tab (Task 4):** Toggle System Audio; confirm the status-bar checkmark
      matches. Switch codec to HEVC, record a clip, confirm it plays back as HEVC. Set GIF fps
      and max width, export a GIF from History, confirm both are honored.
- [ ] **Uploads tab folds in Destinations (Task 5):** Status-bar → **Manage Destinations…**
      now opens Preferences pre-selected on Uploads. Toggle "Upload after capture"; confirm
      the same-named status-bar checkmark follows it. Add an S3 (or Imgur/SFTP/FTP)
      destination and then remove it; confirm no regression in the Keychain-first
      store/purge flow (same behavior as before this feature — see `docs/smoke-m5a.md` for
      the detailed SFTP/FTP Keychain checklist).
- [ ] **Active uploader:** Add two uploaders. The first becomes active; adding the second
      preserves the first selection. Choose the second with **Active uploader**, reopen
      Settings, and confirm the choice persists. Only the selected uploader receives captures.
- [ ] **Clipboard:** With upload off, capture and paste an image. With upload on, wait for
      success and paste the uploaded URL. Simulate a failed upload; the captured image stays
      on the clipboard. Removing the active uploader turns upload off until another is selected.
- [ ] **Delayed upload:** While an upload is pending, copy text in another app or turn
      upload off and capture again. The old upload must not replace the newer clipboard
      contents; its URL should still appear in history.
- [ ] **Hotkeys tab: live recorder + re-register (Task 7):** Click the Fullscreen recorder,
      press a new combo (e.g. ⌃⌥⇧2); the field updates immediately. Without relaunching,
      confirm the NEW combo triggers a fullscreen capture and the OLD combo (⌥⇧3) no longer
      does anything (proves the old Carbon registration was actually unregistered, not just
      shadowed). Click "clear" on a hotkey and confirm it stops firing. Repeat for
      Region/Window/Record.
- [ ] **Recorder monitor teardown on window close:** In the Hotkeys tab, click a hotkey field so it shows "Press a key…", then close the Settings window via the red traffic-light button WITHOUT pressing a key. Reopen Settings (⌘,) and confirm the next keystroke you type elsewhere is NOT swallowed (i.e. the stale key-capture monitor was torn down). (A belt-and-suspenders NSWindow.willCloseNotification teardown was added for this; this verifies it.)

M1 capture smoke: see `docs/smoke-m1.md`. M2a upload smoke: see `docs/smoke-m2a.md`.
M4 recording smoke: see `docs/smoke-m4.md`. M5a SFTP/FTP smoke: see `docs/smoke-m5a.md`.
M5b release/polish smoke: see `docs/smoke-m5b.md`.
