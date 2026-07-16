#!/usr/bin/env bash
set -euo pipefail

# Build a distributable FastMDReader.app: release build -> Developer ID signature with
# hardened runtime -> Apple notarization -> stapled ticket -> Gatekeeper verification.
# The output runs on any arm64 Mac without a quarantine prompt.
#
# One-time setup (already done on this machine; see docs/NOTARIZATION.md to redo):
#   - "Developer ID Application" certificate in the login keychain
#   - notarytool credentials stored as a keychain profile (App Store Connect API key)

IDENTITY="${IDENTITY:-Developer ID Application: DubDubDub Corp. (GTX7V638TX)}"
PROFILE="${NOTARY_PROFILE:-ww-w-notary}"
APP="FastMDReader.app"
ZIP="FastMDReader.zip"

cd "$(dirname "$0")/.."

echo "==> Building release"
./Scripts/make-app.sh release

echo "==> Signing with Developer ID + hardened runtime"
# No --deep: the bundle is a single binary with no embedded frameworks or dylibs,
# and Apple deprecated --deep for distribution signing.
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
