# Smoke: Developer ID signing + notarization

Manual checklist. Nothing here can be verified in CI or on the dev Mac — it needs a
published dmg and, for the Gatekeeper checks, a Mac that has never run Lumeshot.

## Before the first signed release

1. Run `scripts/setup-developer-id.sh` and let it finish its own verification stage.
   - [ ] All six secrets report present.
   - [ ] `gh secret list` shows them with a recent timestamp.

## The release build

2. Tag and push (`git tag v0.2.0 && git push origin v0.2.0`), then watch the run.
   - [ ] "Import Developer ID certificate" logs an identity hash, not an error.
   - [ ] "Verify the signing identity" prints `Signed by team <your team id>`.
   - [ ] "Notarize and staple" ends with `status: Accepted`, then `The staple and validate
         action worked!`.
   - [ ] The Gatekeeper assessment in that step prints `source=Notarized Developer ID`.
   - [ ] The release has both the dmg and `SHA256SUMS.txt` attached.

If notarization is rejected, the step dumps the notary log — that log is the only place
that says *why*. Common causes: missing hardened runtime, a missing secure timestamp, or an
unsigned nested binary.

## On a clean Mac (the part that actually matters)

3. Download the dmg **through a browser** so it carries the quarantine attribute. Copying it
   over ssh or via a shared folder does not, and would make every check below pass
   vacuously.
   - [ ] `xattr -p com.apple.quarantine Lumeshot-0.2.0.dmg` prints a value.
4. Verify before opening:
   - [ ] `spctl --assess --type open --context context:primary-signature -v Lumeshot-0.2.0.dmg`
         → `accepted`, `source=Notarized Developer ID`.
   - [ ] `xcrun stapler validate Lumeshot-0.2.0.dmg` → `The validate action worked!`.
   - [ ] Disconnect from the network and re-run `stapler validate` — it must still pass.
         That is the whole point of stapling.
5. Install and launch:
   - [ ] The dmg opens with a plain double-click — **no** right-click → Open, no
         "unidentified developer" dialog.
   - [ ] Drag to Applications, launch, and macOS shows the ordinary "downloaded from the
         Internet" prompt once, not a Gatekeeper refusal.
   - [ ] `codesign -d --verbose=2 /Applications/Lumeshot.app` shows
         `flags=0x10000(runtime)` and your `TeamIdentifier`.

## Notifications (the reason for doing this)

6. Grant Screen Recording when prompted, then take a capture (⌥⇧3).
   - [ ] A **notification actually appears**. This is the regression that motivated
         notarization: the self-signed build was never registered with Notification Center,
         so notifications silently did nothing.
   - [ ] Clicking the notification reveals the file.
   - [ ] With an upload destination configured, the "Uploaded" notification fires and
         clicking it opens the URL.

## Runtime under the hardened runtime

7. Exercise the paths most likely to break under library validation:
   - [ ] Region and window capture (⌥⇧4 / ⌥⇧5).
   - [ ] A screen recording (⌥⇧6), then "Export as GIF…".
   - [ ] An SFTP or FTP upload — these go through libcurl and Citadel, the only
         non-Foundation network code.
   - [ ] Preferences opens and the hotkey recorder still re-registers.
