# M5a manual smoke checklist (SFTP + FTP uploaders)

Run on the Mac after `scripts/remote.sh run`. Diagnostics: `~/Library/Logs/ShareX-Mac.log`
(same log the M1/M2a/M4 checklists use — tail it while exercising this list). You'll need a
real SFTP server (password auth + a key-based account) and a real FTP/FTPS server reachable
from the Mac — a local Docker container (e.g. `atmoz/sftp`, `stilliard/pure-ftpd`) is fine.

- [ ] **SFTP password auth:** Destinations → **Add SFTP…**. Fill in host/port/username/remote
      directory/public URL base and a password (leave the key field empty). Add disabled until
      those 4 fields + at least one of password/key are non-empty — confirm the button is
      disabled with an empty password AND empty key, and enables once either is filled.
      Capture something with this destination active and **Upload After Capture** on; confirm
      the file lands in the SFTP server's remote directory and the "Uploaded" notification's
      URL is `publicURLBase + "/" + filename`.
- [ ] **SFTP private-key auth (+ passphrase):** Add a second SFTP destination pointed at a
      key-based account; paste a private key (PEM) into the key field, with and without a
      passphrase (two runs). Confirm both authenticate and upload successfully.
  - [ ] **Task 8 checkpoint — Citadel key-init calls:** if the Ed25519/RSA key-init calls in
        `CitadelSFTPTransport` need adjustment for the resolved Citadel SDK (the
        `// VERIFY on Mac` comments in `Sources/SXUpload/CitadelSFTPTransport.swift`), fix them
        here — do not silently work around it in the UI layer.
- [ ] **SFTP result URL reachable:** Open the URL from the "Uploaded" notification in a
      browser (or `curl -I`); confirm it 200s / the file is reachable at `publicURLBase`.
- [ ] **SFTP connect/auth failure:** Point a destination at an unreachable host or wrong
      password; capture; confirm the local file + History row remain (`uploadFailed`), and an
      "Upload failed… Local file kept" notification appears — no crash, no silent drop.
- [ ] **FTP (plain):** Destinations → **Add FTP…**. Fill in host/port/username/remote
      directory/public URL base/password, leave **Use FTPS (TLS)** off. Add disabled until all
      5 fields are non-empty. Capture with this destination active; confirm the file lands on
      the FTP server and the result URL is reachable.
- [ ] **FTPS (TLS):** Add a second FTP destination with **Use FTPS (TLS)** on, pointed at a
      TLS-capable FTP server; confirm the upload succeeds over TLS (check the server's own
      logs/config to confirm it actually negotiated TLS, not a plaintext fallback).
  - [ ] **Task 6 checkpoint — libcurl TLS flags:** if `CURLOPT_USE_SSL`/`CURLUSESSL_ALL` need
        adjustment for the resolved libcurl headers (the `// VERIFY on Mac` comments in
        `Sources/SXUpload/CurlFTPTransport.swift`), fix them here.
- [ ] **FTP connect/auth failure:** Point a destination at an unreachable host or wrong
      password; capture; confirm the local file + History row remain (`uploadFailed`), and an
      "Upload failed… Local file kept" notification appears.
- [ ] **Secrets invariant — settings.json:** After adding one SFTP and one FTP destination,
      inspect `~/Library/Application Support/ShareX-Mac/settings.json`. Confirm the SFTP/FTP
      destination entries contain ONLY `host`/`port`/`username`/`remoteDirectory`/
      `publicURLBase`/`useTLS` — no `password`, no key material, no passphrase, anywhere in the
      file (`grep -i "password\|BEGIN.*PRIVATE KEY\|passphrase" ~/Library/Application\ Support/ShareX-Mac/settings.json`
      must return nothing for these destinations).
- [ ] **Secrets invariant — Keychain purge on remove:** Note the SFTP destination's id (visible
      via its row, or by grepping `settings.json` before removing). Remove it from
      Destinations. Confirm the Keychain items are gone:
      `security find-generic-password -a "<id>/sftp/password" -s org.sharexmac.app` and the
      `/sftp/privateKey` and `/sftp/passphrase` variants all fail with "item could not be
      found" (exit non-zero). Repeat for the FTP destination's `<id>/ftp/password`.
- [ ] **Add-sheet validation:** In both Add sheets, confirm Add stays disabled with any
      required field empty, and — for SFTP specifically — confirm Add stays disabled when both
      password AND private key are empty, and enables as soon as either is filled.
- [ ] **kindLabel:** Confirm the Destinations list shows "SFTP" and "FTP" (not the raw enum
      case name) for the two new rows.

M1 capture smoke: see `docs/smoke-m1.md`. M2a upload smoke: see `docs/smoke-m2a.md`.
M4 recording smoke: see `docs/smoke-m4.md`.
