#!/usr/bin/env bash
set -euo pipefail

# Build a distributable FastMDReader.app: release build -> Developer ID signature with
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
APP="FastMDReader.app"
ZIP="FastMDReader.zip"

echo "==> Building release"
./Scripts/make-app.sh release

echo "==> Signing with Developer ID + hardened runtime"
# No --deep: the bundle is a single binary with no embedded frameworks or dylibs,
# and Apple deprecated --deep for distribution signing.
# Same sandbox entitlements as the App Store build — the sandbox is optional outside the store, but
# shipping an unsandboxed build here would mean the widely-tested binary isn't the one under review.
codesign --force --options runtime --timestamp \
  --entitlements Resources/FastMDReader.entitlements --sign "$IDENTITY" "$APP"
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
