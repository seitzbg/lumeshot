# Bundled third-party notices

- `curl.txt`: https://github.com/curl/curl/blob/curl-8_7_1/COPYING
  (macOS supplies the linked libcurl).
- `boringssl.txt`: https://github.com/google/boringssl/blob/0226f30467f540a3f62ef48d453f93927da199b6/LICENSE
  (the revision recorded in Swift Crypto 3.15.1's `Package.swift`). Refresh this
  when the vendored BoringSSL revision changes.

Other package notices and Citadel's bundled bcrypt/Blowfish source notices are
collected from `.build/checkouts` by `scripts/generate-credits.py`.
SQLite's public-domain dedication is documented at https://www.sqlite.org/copyright.html.
