# Smoke: Picsur destination

Manual checklist — the unit tests cover URL composition and secret handling against a
fake HTTP client; this verifies a real round-trip to a live Picsur instance.

Prereqs: a Picsur instance (e.g. `https://pic.bsd-unix.net`) and an API key created
under **Settings → API keys** in the Picsur web UI.

## Add the destination

1. `scripts/remote.sh run` to launch, then **⌘,** → **Uploads** → **Add Picsur…**.
2. Enter the host **without** a scheme (e.g. `pic.bsd-unix.net`) to exercise
   normalization, paste the API key, leave format `.png` / link **Direct image**.
   - [ ] **Add** is disabled until both host and key are non-empty.
   - [ ] After adding, the row reads the given name with subtitle **Picsur**, and it
         is active if it is the first uploader. Otherwise, select it with **Active uploader**.
3. Confirm the key did **not** land in settings.json:
   - [ ] `grep -ic '<first 6 chars of key>' ~/Library/Application\ Support/Lumeshot/settings.json`
         returns `0`, and the file shows `"kind":"picsur"` with only host/format/linkStyle.
   - [ ] `security find-generic-password -s org.lumeshot.app -a '<destination-id>/picsur/apiKey'`
         finds the entry.

## Upload

4. Enable **Upload after capture**, then take a region capture (⌥⇧4).
   - [ ] Notification fires / URL lands on the clipboard.
   - [ ] The copied URL is `https://<host>/i/<id>.png` and opens the image directly
         in a browser (not the viewer page).
   - [ ] The image appears in the Picsur web UI.
5. Open the history browser.
   - [ ] The row records the result URL, and a thumbnail URL of the form
         `/i/<id>.jpg?width=128&shrinkonly=yes`.
   - [ ] If the API key has delete rights, **Delete remote upload…** removes the
         image from Picsur and clears the remote link while keeping the local file.
         Lumeshot uses the saved API key with `POST /api/image/delete/key`;
         opening the stored browser deletion URL without authentication can be denied.
   - [ ] If the key has **no** delete rights, no deletion URL is recorded
         (rather than a dangling `/api/image/delete/<id>/`).
   - [ ] In **Settings → Uploads → Test uploader**, upload the generated PNG,
         then **Delete test upload…**. The sheet confirms deletion and the test
         image is no longer available on Picsur. Also test with guest deletion
         disabled on the server: the saved API key must still be used.
   - [ ] A denied request or missing image does not claim success or discard its
         deletion link. The sheet keeps its result and shows a readable error.

## Variants + failure paths

6. Add a second Picsur destination with format `.webp` and link **Viewer page**.
   - [ ] Copied URL is `https://<host>/view/<id>` and renders the Picsur viewer.
   - [ ] Switching the active destination between the two changes the copied link style.
7. Add a destination with a deliberately wrong API key and capture.
   - [ ] Upload fails visibly (error notification / log line) and nothing bogus —
         no `…/i/.png` — is copied to the clipboard.
8. Remove a Picsur destination.
   - [ ] The Keychain entry `<id>/picsur/apiKey` is gone (`security find-generic-password`
         above now fails).
