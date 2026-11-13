#!/bin/bash
# Build Dice.app with SwiftPM + Command Line Tools only (no Xcode).
#   scripts/build-app.sh            -> build/Dice.app, signed ad hoc
#   DICE_SIGN_IDENTITY="Name" ...   -> signed with that identity instead
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Dice.app"
ICONDIR="build/icon"

echo "==> swift build -c release"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> rendering AppIcon.icns"
mkdir -p "$ICONDIR"
swiftc -O -parse-as-library scripts/make-icon.swift Sources/Dice/DieArt.swift -o "$ICONDIR/make-icon"
"$ICONDIR/make-icon" "$ICONDIR/AppIcon.iconset" "$ICONDIR/AppIcon.icns"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Dice" "$APP/Contents/MacOS/Dice"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICONDIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Prefer the local "Dice Signing" certificate when it exists: a stable identity keeps the
# Accessibility grant valid across rebuilds. Ad hoc signing invalidates it every time.
IDENTITY="${DICE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -p codesigning 2>/dev/null | grep -q '"Dice Signing"'; then
  IDENTITY="Dice Signing"
fi
echo "==> codesign (${IDENTITY:-ad hoc})"
codesign --force --sign "${IDENTITY:--}" "$APP"
codesign --verify --verbose=1 "$APP"

echo "==> done: $(pwd)/$APP"
