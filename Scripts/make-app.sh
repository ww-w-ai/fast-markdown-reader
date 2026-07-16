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
BIN="$(swift build -c "$CONFIG" --show-bin-path)/FastMDReader"
APP="FastMDReader.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FastMDReader"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# bundle runtime resources (mermaid.min.js added in Task 5, etc.) — everything in Resources/ except
# build inputs that must not ship inside the bundle (Info.plist is placed above; entitlements are a
# signing input).
find Resources -type f ! -name 'Info.plist' ! -name '*.entitlements' -exec cp {} "$APP/Contents/Resources/" \;
# Ad-hoc sign so Gatekeeper allows local launch. Unsandboxed by default, matching the Developer ID
# build people actually download (Scripts/notarize.sh).
#
# SANDBOX=1 signs with the sandbox to exercise the folder-grant path. It uses
# FastMDReader.entitlements — the same sandbox as the store, but WITHOUT the App Store identifiers:
# a build carrying those refuses to launch outside the store ("Launchd job spawn failed"), so the
# real App Store shape can only be tested by installing from the store.
if [[ -n "${SANDBOX:-}" ]]; then
  codesign --force --sign - --entitlements Resources/FastMDReader.entitlements "$APP"
  echo "Built $APP (SANDBOXED — local sandbox test shape)"
else
  codesign --force --sign - "$APP"
  echo "Built $APP"
fi
