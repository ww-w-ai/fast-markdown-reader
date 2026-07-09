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
# bundle runtime resources (mermaid.min.js added in Task 5, etc.) — everything in Resources/ except Info.plist
find Resources -type f ! -name 'Info.plist' -exec cp {} "$APP/Contents/Resources/" \;
# ad-hoc sign so Gatekeeper allows local launch
codesign --force --deep --sign - "$APP"
echo "Built $APP"
