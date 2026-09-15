#!/bin/bash
# Builds Snipiko and installs it to /Applications.
#
# Always signs with the "Snipiko Local Dev" identity so the Screen Recording
# grant survives rebuilds. Never build with CODE_SIGNING_ALLOWED=NO -- that
# produces a linker-signed bundle with no entitlements, which can never hold
# the permission.
#
# Usage:
#   scripts/build.sh            build + install to /Applications
#   scripts/build.sh --no-install   build only, leaves the app in build/

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="Snipiko Local Dev"
# DerivedData must live OUTSIDE ~/Desktop: macOS stamps com.apple.provenance on
# everything created inside protected folders, and codesign refuses to sign a
# bundle carrying it ("resource fork, Finder information, or similar detritus").
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Snipiko-build"
BUILT="$DERIVED/Build/Products/Release/Snipiko.app"
INSTALL_DIR="/Applications"

if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "Signing identity '$IDENTITY' not found."
    echo "Run scripts/make-signing-cert.sh first."
    exit 1
fi

echo "Building Release..."
xcodebuild -project "$ROOT/Snipiko.xcodeproj" -scheme Snipiko -configuration Release \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
    build

echo
echo "Verifying signature..."
codesign --verify --strict --verbose=2 "$BUILT"
codesign -d -r- "$BUILT" 2>&1 | grep designated
codesign -d --entitlements - "$BUILT" 2>&1 | grep -q app-sandbox \
    || { echo "ERROR: entitlements missing from the bundle"; exit 1; }

if [[ "${1:-}" == "--no-install" ]]; then
    echo
    echo "Built: $BUILT"
    exit 0
fi

echo
echo "Installing to $INSTALL_DIR..."
if pgrep -x Snipiko >/dev/null; then
    echo "Quitting the running copy..."
    osascript -e 'quit app "Snipiko"' 2>/dev/null || pkill -x Snipiko || true
    while pgrep -x Snipiko >/dev/null; do sleep 0.2; done
fi
rm -rf "$INSTALL_DIR/Snipiko.app"
cp -R "$BUILT" "$INSTALL_DIR/"

echo "Launching..."
open "$INSTALL_DIR/Snipiko.app"
echo "Done. Snipiko is in the menu bar."
