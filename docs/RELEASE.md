# Release & Deployment

How to cut a TestFlight / App Store build of Brain. The whole cycle is
scripted in [`scripts/release.sh`](../scripts/release.sh) and runs
headless (no Xcode GUI, no prompts) once the one-time setup below is in
place.

## TL;DR

```bash
# Run the test gate first (see "Gate" below), then:
scripts/release.sh --version 0.6.0 --bump-build   # new user-facing version
scripts/release.sh --bump-build                   # same version, next build
```

Then commit the `project.yml` bump, update the Releases list in
[`README.md`](../README.md), and push.

## What the script does

1. Edits `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`
   per the flags.
2. `xcodegen generate` (the `.xcodeproj` is generated and gitignored).
3. `xcodebuild archive` for `generic/platform=iOS`, signed via the App
   Store Connect API key with `-allowProvisioningUpdates`.
4. `xcodebuild -exportArchive` with [`scripts/ExportOptions.plist`](../scripts/ExportOptions.plist)
   (`method app-store-connect`, `destination upload`) — exports **and
   uploads** in one step.

Artifacts land in `build/` (gitignored).

## Version vs build number

Two independent fields in `project.yml`:

| Field | Meaning | When to bump |
|---|---|---|
| `MARKETING_VERSION` | User-facing version (e.g. `0.5.0`) — shows in the App Store | New user-facing release |
| `CURRENT_PROJECT_VERSION` | Build number (e.g. `5`) — the `(N)` | **Every** upload |

App Store Connect **rejects an upload whose `(MARKETING_VERSION,
CURRENT_PROJECT_VERSION)` pair it has already seen.** So every upload
needs a fresh build number. `--bump-build` handles this; always pass it.

## Flags

- `--version X.Y.Z` — set the marketing version.
- `--bump-build` — increment the build number by 1.
- `--build N` — set the build number explicitly.

## One-time setup (already done on the primary Mac — 2026-06-29)

These are the prerequisites that bit us the first time. If you move to a
new machine or the credentials rotate, redo them.

### 1. App Store Connect API key

Authenticates both distribution signing and the upload, with no Apple ID
prompt.

1. App Store Connect → **Users and Access → Integrations → Keys** → **+**.
   Role **Admin** (or App Manager). **Generate**, **download the `.p8`
   once.**
2. Note the **Key ID** (key row) and **Issuer ID** (above the list).
3. Install:
   ```bash
   mkdir -p ~/.appstoreconnect/private_keys
   mv ~/Downloads/AuthKey_<KEYID>.p8 ~/.appstoreconnect/private_keys/
   chmod 600 ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8
   cp scripts/.release.env.example scripts/.release.env   # then fill in IDs
   ```
   `scripts/.release.env` (gitignored) holds `ASC_KEY_ID` and
   `ASC_ISSUER_ID`. The `.p8` never goes in the repo.

### 2. Apple Distribution certificate

App Store export must sign with an **Apple Distribution** cert that has
its private key in the local keychain. `-allowProvisioningUpdates`
auto-creates *profiles* but **not** the distribution *certificate*, and
GUI uploads use a cloud-managed cert the CLI can't reuse — so create one
explicitly, once:

- **Xcode → Settings → Accounts → (team `XCHXTX3N92`) → Manage
  Certificates → + → Apple Distribution.**

Verify it's present:
```bash
security find-identity -v -p codesigning | grep Distribution
```

## Gate: run the tests before releasing

```bash
DEV=$(xcrun simctl list devices available | awk '/-- iOS [0-9.]+ --/{r=$0} /iPhone 1[0-9] /{print $NF; exit}' | tr -d '()')
xcodebuild test -project Brain.xcodeproj -scheme Brain \
  -destination "platform=iOS Simulator,id=$DEV" CODE_SIGNING_ALLOWED=NO
```

Expect `BrainTests` (unit) and `BrainUITests` (e2e) green. The simulator
runtime must match the installed Xcode (Xcode → Settings → Components);
a mismatch shows up as "Application failed preflight checks" launch
failures or destination-resolution errors, not test logic failures.

## Troubleshooting (the things that cost us a cycle)

### `exportArchive Copy failed` / `rsync: --extended-attributes: unknown option`
Xcode's IPA-packaging step runs `rsync -E`. `/usr/bin/rsync` (Apple
openrsync) supports it, but a **Homebrew rsync 3.x earlier in PATH** is
picked up for the spawned peer and rejects the flag. `release.sh` fixes
this by prepending `/usr/bin` to PATH. If you invoke `xcodebuild
-exportArchive` by hand, do the same: `PATH="/usr/bin:$PATH" xcodebuild …`.

### `No "iOS Distribution" signing certificate found`
The Apple Distribution cert is missing — see one-time setup §2.

### `PLA Update available` / "agree to the latest Program License Agreement"
Apple froze membership resources (cert creation, uploads) pending a new
agreement. The **Account Holder** must accept it at
[developer.apple.com/account](https://developer.apple.com/account), then
retry. This also surfaces as a downstream "No iOS Distribution
certificate" error.

### Duplicate-build rejection
You uploaded a `(version, build)` pair already seen. Bump the build
(`--bump-build`) and re-run.

## After upload

The build appears under **App Store Connect → TestFlight** as
`X.Y.Z (N)` after a few minutes of processing. Export compliance is
declared exempt in `Brain.entitlements`
(`ITSAppUsesNonExemptEncryption: NO`), so no per-upload prompt. Add to
testers or submit the version for review from there.
