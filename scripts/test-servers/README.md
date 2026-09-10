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

Every port is published on `LUMESHOT_TEST_HOST`, which defaults to `127.0.0.1`.
The servers hold a writable account, so reaching them from another machine is
opt-in — set the address explicitly when the Swift toolchain and Docker are on
different hosts (Swift builds happen on the Mac; Docker runs on the Linux box):

```sh
LUMESHOT_TEST_HOST=192.0.2.1 ./up.sh
```

The account password is generated on first `up.sh` and kept in `state/password`,
so nothing publishes a credential that is also written down in this repo.

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
| `password` | the generated account password, shared by both servers |
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
