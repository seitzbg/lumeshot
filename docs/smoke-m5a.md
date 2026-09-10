# M5a smoke checklist (SFTP + FTP uploaders)

Most of what this checklist used to ask a human to do now runs as automated
tests against real servers. `scripts/test-servers/up.sh` starts a throwaway
SFTP, FTP and HTTP server in Docker, prints the environment to export, and
`swift test` then drives `SFTPUploader`/`FTPUploader` — the real
`CitadelSFTPTransport` and `CurlFTPTransport`, not fakes — against them:

```sh
scripts/test-servers/up.sh          # prints the LUMESHOT_LIVE_* exports
# export them where `swift test` runs, then:
swift test --filter "LiveSFTPTransportTests|LiveFTPTransportTests"
scripts/test-servers/down.sh --clean
```

Without `LUMESHOT_LIVE_UPLOAD_HOST` the suites skip, so CI and a plain
`swift test` are unaffected. `Tests/LumeshotUploadTests/LiveUploadServerTests.swift`
covers, for both protocols: a successful upload whose **public URL actually
serves the uploaded bytes**, a wrong password (typed error, nothing written), an
unreachable port, and — for SFTP — password auth, Ed25519 key auth, Ed25519 +
passphrase, a wrong passphrase, trust-on-first-use learning the fingerprint, and
a pinned fingerprint refusing a changed host key. The Task 8 "VERIFY on Mac"
checkpoint is resolved: the Citadel key-init calls are exercised on every run.

Two findings came out of automating it:

- **RSA private keys do not work against current SSH servers.** Citadel can only
  sign with the legacy `ssh-rsa` (SHA-1) algorithm, which OpenSSH has excluded
  from `PubkeyAcceptedAlgorithms` by default since 8.8. The upload error now
  names that cause and points at Ed25519 instead of reporting an opaque
  `allAuthenticationOptionsFailed`.
- **FTPS is proven not to fall back to plaintext**, but not proven end to end.
  The test server presents a self-signed certificate, so `useTLS: true` fails
  verification while a plaintext upload to the same host and port succeeds —
  which is what shows `CURLOPT_USE_SSL` reaching libcurl. A *successful* FTPS
  transfer needs a certificate the Mac trusts, so it stays below.

## Still manual

Run on the Mac after `scripts/remote.sh run`. Diagnostics: `~/Library/Logs/Lumeshot.log`.

- [ ] **FTPS (TLS) against a trusted certificate:** add an FTP destination with
      **Use FTPS (TLS)** on, pointed at a TLS-capable server whose certificate
      the Mac trusts; confirm the upload succeeds and the server's own log shows
      it negotiated TLS rather than falling back to plaintext.
- [ ] **Add-sheet validation:** in both Add sheets, confirm Add stays disabled
      with any required field empty, and — for SFTP — that it stays disabled when
      both password AND private key are empty and enables as soon as either is
      filled.
- [ ] **kindLabel:** confirm the Destinations list shows "SFTP" and "FTP" (not the
      raw enum case name) for the two rows.
- [ ] **End-to-end through the app:** with an SFTP destination active and **Upload
      After Capture** on, capture something; confirm the file lands on the server
      and the "Uploaded" notification carries `publicURLBase + "/" + filename`.
      (The uploader half of this is covered above; what is left is the capture →
      pipeline → notification wiring.)

Covered by unit tests, not re-verified here: secrets never reach `settings.json`
(`SFTPFTPDestinationTests.encodedSettingsCarryNoCredentialMaterialForSFTPOrFTP`),
and the Keychain purge on destination removal (`SFTPCredentialsTests`,
`FTPCredentialsTests`).

M1 capture smoke: see `docs/smoke-m1.md`. M2a upload smoke: see `docs/smoke-m2a.md`.
M4 recording smoke: see `docs/smoke-m4.md`.
