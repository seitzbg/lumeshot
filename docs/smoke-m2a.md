# M2a manual smoke checklist

Run on the Mac after `scripts/remote.sh run`. Diagnostics: `~/Library/Logs/ShareX-Mac.log`.

- [ ] Menu shows "Import .sxcu…" and "Upload After Capture" (with a checkmark state)
- [ ] Import a real .sxcu (e.g. an Imgur or self-hosted config) → "Uploader imported" notification; it becomes the active destination
- [ ] Toggle "Upload After Capture" on
- [ ] Capture fullscreen (⌥⇧3) → local file still saved to ~/Pictures/ShareX (local-first), then an "Uploaded" notification appears with the URL
- [ ] Clipboard holds the URL (⌘V into a text field) — not the image — after a successful upload
- [ ] Clicking the "Uploaded" notification opens the URL in the browser
- [ ] The uploaded image is actually reachable at the URL
- [ ] Turn off Wi‑Fi, capture → local file saved, "Upload failed … Local file kept" notification, no clipboard URL (capture not lost)
- [ ] history.sqlite exists at ~/Library/Application Support/ShareX-Mac/ and has rows (verify: `sqlite3 ~/Library/Application\ Support/ShareX-Mac/history.sqlite 'select url,upload_failed from history'`)
- [ ] Import a .sxcu with an Authorization header → the header value is NOT present in ~/Library/Application Support/ShareX-Mac/settings.json (it's `$keychain$`); the secret is in the login keychain
- [ ] Import a malformed / XML-body .sxcu → clear "Import failed" notification, no crash
