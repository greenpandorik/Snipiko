#!/bin/bash
# Builds Snipiko and packages it as a DMG for distribution.
#
# Read scripts/make-signing-cert.sh first: without an Apple Developer ID the app
# is signed locally, and Gatekeeper on anyone else's Mac will refuse to open it
# until they allow it by hand. Set DEVELOPMENT_TEAM and notarize for a clean
# install -- see the Distribution section of the README.
#
# Usage: scripts/package.sh [version]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(date +%Y.%m.%d)}"
IDENTITY="${SNIPIKO_IDENTITY:-Snipiko Local Dev}"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Snipiko-package"
BUILT="$DERIVED/Build/Products/Release/Snipiko.app"
OUT="$ROOT/dist"
DMG="$OUT/Snipiko-$VERSION.dmg"

# "-" means ad-hoc: no certificate, used on CI when none is stored.
if [ "$IDENTITY" != "-" ] && ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "Signing identity '$IDENTITY' not found. Run scripts/make-signing-cert.sh."
    exit 1
fi

LOG="$(mktemp)"
echo "Building $VERSION..."
rm -rf "$DERIVED"
xcodebuild -project "$ROOT/Snipiko.xcodeproj" -scheme Snipiko -configuration Release \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    MARKETING_VERSION="$VERSION" \
    OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
    build > "$LOG" 2>&1 || {
        echo "Build failed. Compiler errors:"
        grep -E "error:" "$LOG" | head -40
        echo "--- last lines ---"
        tail -20 "$LOG"
        exit 1
    }

codesign --verify --strict "$BUILT"
codesign -d --entitlements - "$BUILT" 2>&1 | grep -q app-sandbox \
    || { echo "ERROR: entitlements missing"; exit 1; }

echo "Staging..."
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$BUILT" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# Shown on first open, because an unnotarized app needs a manual step.
cat > "$STAGE/Прочти меня.txt" <<'NOTE'
Установка Snipiko

1. Перетащите Snipiko в папку Applications.
2. Запустите. macOS скажет, что не может проверить разработчика — это ожидаемо:
   приложение подписано, но не заверено в Apple.
3. Откройте Системные настройки -> Конфиденциальность и безопасность,
   пролистайте вниз и нажмите «Открыть всё равно» рядом с Snipiko.
4. Запустите снова и выдайте доступ к записи экрана, затем перезапустите Snipiko.

Если шаг 3 не помогает, выполните в Терминале:
   xattr -dr com.apple.quarantine /Applications/Snipiko.app
NOTE

mkdir -p "$OUT"
rm -f "$DMG"
echo "Packaging $DMG..."
hdiutil create -volname "Snipiko" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

[ "$IDENTITY" = "-" ] || codesign --force --sign "$IDENTITY" "$DMG" 2>/dev/null || true

echo
echo "Готово: $DMG"
echo "размер: $(du -h "$DMG" | cut -f1)"
spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | sed 's/^/  gatekeeper: /' || true
