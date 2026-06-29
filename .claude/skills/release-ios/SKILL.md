---
name: release-ios
description: Cut a TestFlight / App Store build of the Brain iOS app — bump the version, run the test gate, archive, and upload to App Store Connect headlessly via scripts/release.sh. Use when asked to "release", "ship", "cut a build", "push to the App Store / TestFlight", "deploy the iOS app", or bump the app version. Bakes in the signing + rsync gotchas so they don't recur.
---

# Release the Brain iOS app

Full runbook: [`docs/RELEASE.md`](../../../docs/RELEASE.md). This skill is
the short, do-it path. Read the runbook for the one-time setup and the
why behind each gotcha.

## Steps

1. **Confirm scope with the user**: new user-facing version (e.g.
   `0.6.0`) or just a new build of the current version? Uploading is an
   irreversible outward action — confirm before pushing unless they
   already said "release X.Y.Z".

2. **Run the test gate** (don't ship red):
   ```bash
   DEV=$(xcrun simctl list devices available | awk '/-- iOS [0-9.]+ --/{r=$0} /iPhone 1[0-9] /{print $NF; exit}' | tr -d '()')
   xcodebuild test -project Brain.xcodeproj -scheme Brain \
     -destination "platform=iOS Simulator,id=$DEV" CODE_SIGNING_ALLOWED=NO
   ```
   `BrainTests` + `BrainUITests` must pass. Launch failures
   ("Application failed preflight checks") or destination errors mean
   the simulator runtime ≠ Xcode version — that's environment, not the
   code; tell the user to install the matching runtime (Xcode →
   Settings → Components). UI tests run on a cold sim can be slow —
   that's expected.

3. **Release** (this archives AND uploads — runs a few minutes; use a
   background shell):
   ```bash
   scripts/release.sh --version X.Y.Z --bump-build   # new version
   scripts/release.sh --bump-build                   # next build only
   ```
   **Always `--bump-build`** — App Store Connect rejects a re-used
   `(version, build)` pair.

4. **Record it**: commit the `project.yml` bump, add an entry to the
   Releases list in `README.md`, push `main`. Use the project's commit
   trailers.

## Non-negotiables / gotchas (already handled, keep them that way)

- **Build number must increase every upload.** `--bump-build`.
- **rsync**: `release.sh` prepends `/usr/bin` to PATH. If you ever call
  `xcodebuild -exportArchive` directly, do the same — a Homebrew rsync
  3.x in PATH breaks export with a cryptic `Copy failed`
  (`--extended-attributes: unknown option`).
- **Signing prerequisites** (one-time, see runbook): an App Store
  Connect API key in `~/.appstoreconnect/private_keys/` + IDs in the
  gitignored `scripts/.release.env`, and an **Apple Distribution**
  certificate in the keychain (`security find-identity -v -p
  codesigning | grep Distribution`). If the cert is missing, the user
  creates it in Xcode → Settings → Accounts → Manage Certificates → +
  Apple Distribution. `-allowProvisioningUpdates` will NOT mint it.
- **Never commit** `scripts/.release.env` or any `.p8` (both gitignored;
  verify with `git status` before committing).

## Verify

"Upload succeeded" in the export log = done. The build shows under App
Store Connect → TestFlight as `X.Y.Z (N)` after processing. Offer to
poll the ASC API for processing status if the user wants confirmation.
