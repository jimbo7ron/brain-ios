#!/usr/bin/env bash
#
# release.sh — headless archive + upload to App Store Connect.
#
# Runs the whole cycle the Xcode GUI does (Archive → Distribute →
# Upload) from the CLI, using an App Store Connect API key for both
# automatic distribution signing and the upload itself. No prompts.
#
# Credentials (never committed) come from scripts/.release.env or the
# environment:
#     ASC_KEY_ID      — the API key's Key ID (e.g. ABC123XYZ9)
#     ASC_ISSUER_ID   — the issuer UUID from App Store Connect → Keys
#     ASC_KEY_PATH    — path to the AuthKey_<KeyID>.p8 file
#                       (default: ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8)
#
# Usage:
#     scripts/release.sh                 # archive + upload current version
#     scripts/release.sh --bump-build    # +1 the build number first
#     scripts/release.sh --build 7       # set build number to 7
#     scripts/release.sh --version 0.5.0 # set marketing version
#     scripts/release.sh --version 0.5.0 --bump-build
#
# Combine flags freely; version/build edits land in project.yml and are
# regenerated before the archive. Commit those edits yourself afterward.

set -euo pipefail

# Put the system bin ahead of Homebrew. Xcode's `-exportArchive`
# IPA-packaging step shells out to `rsync -E` (extended attributes);
# `/usr/bin/rsync` is Apple's openrsync, which understands it, but a
# Homebrew rsync 3.x earlier in PATH gets picked up for the spawned
# peer process and rejects `--extended-attributes` ("unknown option"),
# failing the export with a cryptic "Copy failed". Prepending /usr/bin
# makes both ends resolve to openrsync.
export PATH="/usr/bin:$PATH"

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# ---- config -----------------------------------------------------------
[ -f scripts/.release.env ] && set -a && . scripts/.release.env && set +a

: "${ASC_KEY_ID:?Set ASC_KEY_ID (App Store Connect API Key ID) in scripts/.release.env}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID (App Store Connect issuer UUID) in scripts/.release.env}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
[ -f "$ASC_KEY_PATH" ] || { echo "✗ API key not found: $ASC_KEY_PATH" >&2; exit 1; }

# ---- args -------------------------------------------------------------
NEW_BUILD=""
NEW_VERSION=""
BUMP_BUILD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --build)   NEW_BUILD="$2"; shift 2;;
    --version) NEW_VERSION="$2"; shift 2;;
    --bump-build) BUMP_BUILD=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

bump_yaml() { # key value
  /usr/bin/sed -i '' -E "s/^( *$1: *).*/\1\"$2\"/" project.yml
}
cur() { /usr/bin/grep -E "^ *$1:" project.yml | head -1 | /usr/bin/sed -E 's/.*"(.*)".*/\1/'; }

[ -n "$NEW_VERSION" ] && { echo "→ MARKETING_VERSION = $NEW_VERSION"; bump_yaml MARKETING_VERSION "$NEW_VERSION"; }
if [ "$BUMP_BUILD" = 1 ]; then
  NEXT=$(( $(cur CURRENT_PROJECT_VERSION) + 1 )); echo "→ CURRENT_PROJECT_VERSION = $NEXT (bumped)"; bump_yaml CURRENT_PROJECT_VERSION "$NEXT"
elif [ -n "$NEW_BUILD" ]; then
  echo "→ CURRENT_PROJECT_VERSION = $NEW_BUILD"; bump_yaml CURRENT_PROJECT_VERSION "$NEW_BUILD"
fi

VERSION=$(cur MARKETING_VERSION); BUILD=$(cur CURRENT_PROJECT_VERSION)
echo "── Releasing Brain $VERSION ($BUILD) ──"

# ---- build ------------------------------------------------------------
echo "→ xcodegen generate"; xcodegen generate >/dev/null

STAMP="$(/bin/date +%Y-%m-%d_%H%M%S)"
ARCHIVE="$ROOT/build/Brain_${VERSION}_${BUILD}_${STAMP}.xcarchive"
EXPORT_DIR="$ROOT/build/export_${STAMP}"

AUTH=(-allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID")

echo "→ archive"
xcodebuild archive \
  -project Brain.xcodeproj -scheme Brain \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  "${AUTH[@]}"

echo "→ export + upload to App Store Connect"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  "${AUTH[@]}"

echo "✓ Uploaded Brain $VERSION ($BUILD) to App Store Connect."
echo "  Watch processing at https://appstoreconnect.apple.com → TestFlight."
