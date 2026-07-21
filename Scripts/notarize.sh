#!/usr/bin/env bash
set -euo pipefail

# Build a distributable FastDocReader.app: release build -> Developer ID signature with
# hardened runtime -> Apple notarization -> stapled ticket -> Gatekeeper verification.
# The output runs on any arm64 Mac without a quarantine prompt.
#
# One-time setup (already done on this machine; see docs/NOTARIZATION.md to redo):
#   - "Developer ID Application" certificate in the login keychain
#   - notarytool credentials stored as a keychain profile (App Store Connect API key)
#
# The signing identity is NOT in this repo — it comes from a config file outside it
# (default: $KEYCHAIN_DIR/signing.env), or from the environment.

cd "$(dirname "$0")/.."

KEYCHAIN_DIR="${KEYCHAIN_DIR:-$HOME/Documents/DEV/ww-w-ai/.keychains}"
[[ -f "$KEYCHAIN_DIR/signing.env" ]] && source "$KEYCHAIN_DIR/signing.env"

: "${IDENTITY:?set IDENTITY (e.g. 'Developer ID Application: <Team> (<TEAMID>)') — see docs/NOTARIZATION.md}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE (notarytool keychain profile name)}"
PROFILE="$NOTARY_PROFILE"
APP="FastDocReader.app"
ZIP="FastDocReader.zip"

echo "==> Building release"
# DIST_IDENTITY keeps the real bundle identifier: a local build otherwise gets a .dev suffix so it
# cannot share per-app state (recent documents above all) with an installed release.
DIST_IDENTITY=1 ./Scripts/make-app.sh release

# Verify it rather than trust the flag — shipping a .dev identifier would be a broken update for
# every existing user, and the symptom (their app "forgetting" everything) appears only after install.
BUILT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' FastDocReader.app/Contents/Info.plist)"
if [[ "$BUILT_ID" == *.dev ]]; then
  echo "REFUSING TO SHIP: bundle identifier is $BUILT_ID — DIST_IDENTITY did not take effect." >&2
  exit 1
fi
echo "    shipping identifier: $BUILT_ID"

echo "==> Signing with Developer ID + hardened runtime (NO sandbox — see below)"
# No --deep: the bundle is a single binary with no embedded frameworks or dylibs,
# and Apple deprecated --deep for distribution signing.
#
# Deliberately NOT sandboxed, unlike the App Store build. The sandbox grants access only to the file
# the user opened, so a document's own `![](diagram.png)` sibling is unreadable — verified: every
# local image form fails under the sandbox while remote ones load. macOS never even prompts, because
# the sandbox denies before TCC is consulted, and there is no "Documents folder" entitlement to ask
# for. The store forces that trade; direct distribution doesn't, so this build keeps local images
# working with no permission step. The App Store build pays for it with an explicit folder grant.
# (Marked 2 ships the same split; Typora/Obsidian/IntelliJ skip the store entirely for this reason.)
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Submitting to Apple for notarization (takes a few minutes)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling ticket (so it validates offline)"
xcrun stapler staple "$APP"

echo "==> Verifying Gatekeeper acceptance"
spctl -a -vvv -t install "$APP"
xcrun stapler validate "$APP"

# Repackage AFTER stapling — the submission zip holds the un-stapled app.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Done. $ZIP is signed, notarized, and stapled — ready to send to anyone."
