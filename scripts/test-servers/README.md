# Live upload test servers

Throwaway SFTP, FTP/FTPS and HTTP servers for the `LumeshotUpload` integration
tests. They exist because `CitadelSFTPTransport` and `CurlFTPTransport` are the
two pieces of the upload path that cannot be exercised with a fake: everything
interesting about them — key parsing, host-key pinning, TLS, libcurl option
plumbing — only shows up against a real server.

```sh
./up.sh                  # generates keys + a certificate, starts the containers,
                         # prints the LUMESHOT_LIVE_* environment to export
./down.sh                # stop
./down.sh --clean        # stop and delete ./state
```

`up.sh` binds to this machine's first LAN address so the tests can run on another
host (Swift builds happen on the Mac; Docker runs on the Linux box). Override it
with `LUMESHOT_TEST_HOST=…`.

Export what `up.sh` prints where `swift test` runs, then:

```sh
swift test --filter "LiveSFTPTransportTests|LiveFTPTransportTests"
```

With `LUMESHOT_LIVE_UPLOAD_HOST` unset the suites skip themselves, so CI and a
plain `swift test` are unaffected.

## What is in ./state

Generated on first `up.sh`, gitignored, never committed:

| Path | What |
| --- | --- |
| `keys/ed25519`, `ed25519-pass`, `rsa` | throwaway client keys — one per branch of the transport's key handling |
| `keys/pub/` | the matching public keys, mounted into the SFTP server as `authorized_keys` |
| `tls/pure-ftpd.pem` | self-signed certificate + key for the FTP server's TLS |
| `sftp-upload/`, `ftp-home/` | what the tests upload; also served by the HTTP container |

The HTTP container serves those two directories, which is how a test checks that
the *public URL the uploader returned* really serves the bytes that were
uploaded — the thing `docs/smoke-m5a.md` used to check by pasting a link into a
browser.

The certificate is self-signed, so an FTPS upload fails verification on purpose;
see the FTPS note in `docs/smoke-m5a.md` for what that does and does not prove.

If the tests run on a different host from Docker, copy the three private keys
over and point `LUMESHOT_LIVE_KEY_DIR` at them — they never need to be inside a
checkout.
