# Preferences window manual smoke checklist

Build and launch the local bundle using `docs/local-development.md`. Diagnostics: `~/Library/Logs/Lumeshot.log`.
Covers the sidebar Settings window (Tasks 1–5, 7) end to end; Task 6's hotkey
formatting/mapping is covered by `Tests/LumeshotCoreTests/HotkeyFormattingTests.swift`, not
re-verified here.

- [ ] **Window opens and reuses (Task 1):** Status-bar menu → **Settings…** (confirm the ⌘,
      keyEquivalent also opens it while the status-bar menu is open). A window titled
      "Lumeshot Settings" appears with 5 sidebar items: General, Capture, Shortcuts, Uploads, Recording.
      Close it and reopen via the menu; confirm it's the same window (position/selected tab
      persist within the app session), not a second window stacking on top.
- [ ] **App switcher:** Open Settings and confirm Lumeshot appears in the Dock and
      ⌘Tab (and AltTab, if installed). Switch away and back. Minimize Settings,
      then click Lumeshot in the Dock to restore it. Hide with ⌘H and switch back.
      Close Settings with the red button or ⌘W: the Dock entry disappears while
      the menu-bar icon and capture hotkeys remain. Reopen Settings and repeat.
- [ ] **General tab persists + live-applies (Task 2):** Toggle each of the 3 switches (Save a copy, Show notifications,
      Open the editor). Confirm
      `settings.json` reflects each change immediately and the "Annotate Before Sharing"
      status-bar checkmark follows the last one.
- [ ] **Capture tab (Task 3):** Confirm the Capture folder shows `~/Pictures/Lumeshot`
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
- [ ] **Shortcuts page: live recorder + re-register (Task 7):** Click the recorder on
      **Capture fullscreen**, press a new combo (e.g. ⌃⌥⇧2); the field updates immediately.
      Without relaunching, confirm the NEW combo triggers a fullscreen capture and the OLD
      combo (⌥⇧3) no longer does anything (proves the old Carbon registration was actually
      unregistered, not just shadowed). Click the ⊗ clear button and confirm it stops firing.
      Repeat for **Capture region**, **Capture window**, and **Start or stop recording**.
- [ ] **Shortcut row alignment (shipped in v0.1.8):** With at least one shortcut assigned and
      at least one cleared, confirm every recorder button has the same width and the same left
      edge — the trailing clear slot stays reserved, so clearing or assigning a shortcut must
      not shift its button sideways. Check all-set and all-unset layouts too. On a cleared row
      the clear button is invisible: confirm it is also inert — clicking where it would be does
      nothing, and keyboard focus skips it.
- [ ] **Recorder monitor teardown on window close:** In the Shortcuts page, click a hotkey field so it shows "Press a key…", then close the Settings window via the red traffic-light button WITHOUT pressing a key. Reopen Settings (⌘,) and confirm the next keystroke you type elsewhere is NOT swallowed (i.e. the stale key-capture monitor was torn down). (A belt-and-suspenders NSWindow.willCloseNotification teardown was added for this; this verifies it.)

M1 capture smoke: see `docs/smoke-m1.md`. M2a upload smoke: see `docs/smoke-m2a.md`.
M4 recording smoke: see `docs/smoke-m4.md`. M5a SFTP/FTP smoke: see `docs/smoke-m5a.md`.
M5b release/polish smoke: see `docs/smoke-m5b.md`.

## Visual refresh checks

- [ ] Resize Settings down to 760 × 560; every page remains usable and scrolls when needed.
- [ ] Switch between light and dark appearance; labels and controls remain readable.
- [ ] Check the custom Lumeshot icon in Finder, the Dock, and the Settings sidebar.
- [ ] Use **Add uploader** to open each provider form. S3 and SFTP scroll to all fields;
      Cancel and Add/Save stay visible. Escape cancels without saving.
- [ ] Check the empty Uploads state, multiple uploaders, and a long uploader name.
- [ ] Type a GIF maximum width and click another control; the value persists.
- [ ] Close and relaunch; the Settings window restores its saved size and position.
