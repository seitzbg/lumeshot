# M1 manual smoke checklist

Run on the Mac after `scripts/remote.sh run`. All boxes must pass to call M1
done. If a step behaves unexpectedly, check `~/Library/Logs/ShareX-Mac.log`
first — the app tees every capture-path log line there (as well as to the
unified log via `NSLog`) specifically because a menu-bar app launched from
Finder has no visible stderr; `tail -f` it on the Mac while exercising this
checklist.

- [ ] Menu-bar camera icon (`camera.viewfinder`) appears; menu lists Capture Region / Capture Window / Capture Full Screen / Open Captures Folder / Quit ShareX for Mac
- [ ] First capture attempt without permission shows the onboarding window (Screen Recording explanation, "Open System Settings", "Relaunch"); System Settings deep-link opens Privacy & Security → Screen Recording; Relaunch quits and relaunches the app
- [ ] ⌥⇧3 (fullscreen) captures all displays → one PNG per display in `~/Pictures/ShareX`, image on clipboard (⌘V into Preview — on multi-display, the last display captured wins the clipboard), notification appears per display
- [ ] Notification click reveals the corresponding file in Finder
- [ ] ⌥⇧4 (region) shows a frozen, dimmed overlay: crosshair follows the cursor, an 8x loupe shows pixel coordinates, dragging shows live selection dimensions in px and un-dims the selected area; release saves+copies+notifies. The ~1s pause between hotkey press and the overlay appearing is the display freeze-capture completing — expected, not a bug
- [ ] ⌥⇧4 then Esc cancels; no file written, overlay gone. A stray click (< 4px drag) does *not* dismiss the overlay — only Esc cancels
- [ ] ⌥⇧5 (window) hover-highlights windows with an accent-color outline and an "App — Title" label; click captures only that window at its own display's backing scale; Esc cancels; if no capturable windows are found, a "No windows to capture" notification appears instead of an overlay
- [ ] Multi-display (if attached): fullscreen and region overlays appear on every screen; capture from a secondary display is correct and Retina-sharp
- [ ] Filenames match `Screenshot_YYYY-MM-DD_HH-MM-SS.png`; a second capture in the same second gets a `_1` suffix
- [ ] Quit from menu; `pgrep -x SXApp` confirms exit
