#!/usr/bin/env bash
set -euo pipefail

# Toolchain: this machine's standalone CommandLineTools has a mismatched SwiftPM
# ManifestAPI (PackageDescription .swiftmodule newer than its .dylib), which breaks
# `swift build`. Xcode ships a consistent toolchain, so prefer it when available.
# Override by exporting DEVELOPER_DIR yourself, or make it permanent with:
#   sudo xcode-select -s /Applications/Xcode.app  (or update Command Line Tools).
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

CONFIG="${1:-debug}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/FastDocReader"
APP="FastDocReader.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FastDocReader"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# A local build gets its OWN bundle identifier, so it cannot touch the installed app's state.
#
# macOS keys per-app state — the recent-documents list above all — to the bundle identifier. A build
# from here is ad-hoc signed, and an ad-hoc signature's cdhash changes on EVERY build, so each one
# reads to macOS as a different app claiming the same identifier. Sharing the identifier with an
# installed release therefore wipes that release's recent files every time a developer rebuilds
# (see the "Open Recent" invariant in CLAUDE.md). Separating the identifier removes the shared state
# entirely, whatever the exact mechanism.
#
# Distribution MUST keep the real identifier: notarize.sh and appstore.sh set DIST_IDENTITY=1, and
# both verify afterwards that it survived — a default that only holds when every future caller
# remembers to opt out is not a default worth having.
if [[ -z "${DIST_IDENTITY:-}" ]]; then
  PB=/usr/libexec/PlistBuddy
  REAL_ID="$($PB -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  $PB -c "Set :CFBundleIdentifier ${REAL_ID}.dev" "$APP/Contents/Info.plist"
  $PB -c "Set :CFBundleName FastDoc (Dev)" "$APP/Contents/Info.plist"
  $PB -c "Set :CFBundleDisplayName Fast Doc Reader (Dev)" "$APP/Contents/Info.plist"
  echo "    identifier: ${REAL_ID}.dev  (local build — separate from any installed release)"
else
  echo "    identifier: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")  (DISTRIBUTION)"
fi
# bundle runtime resources (mermaid.min.js added in Task 5, etc.) — everything in Resources/ except
# build inputs that must not ship inside the bundle (Info.plist is placed above; entitlements are a
# signing input).
find Resources -type f ! -name 'Info.plist' ! -name '*.entitlements' -exec cp {} "$APP/Contents/Resources/" \;
# The KaTeX fonts ride inside katex-inlined.min.css, and the OFL requires its text to travel WITH
# the fonts — so the notices ship in the bundle, not just in the repo.
cp THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/"
cp -R licenses "$APP/Contents/Resources/"
# Ad-hoc sign so Gatekeeper allows local launch. Unsandboxed by default, matching the Developer ID
# build people actually download (Scripts/notarize.sh).
#
# SANDBOX=1 signs with the sandbox to exercise the folder-grant path. It uses
# FastDocReader.entitlements — the same sandbox as the store, but WITHOUT the App Store identifiers:
# a build carrying those refuses to launch outside the store ("Launchd job spawn failed"), so the
# real App Store shape can only be tested by installing from the store.
if [[ -n "${SANDBOX:-}" ]]; then
  codesign --force --sign - --entitlements Resources/FastDocReader.entitlements "$APP"
  echo "Built $APP (SANDBOXED — local sandbox test shape)"
else
  codesign --force --sign - "$APP"
  echo "Built $APP"
fi
