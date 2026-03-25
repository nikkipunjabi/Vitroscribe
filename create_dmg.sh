#!/bin/bash
# Builds Vitroscribe and packages it as a DMG using create-dmg (Sindre Sorhus).
# This produces the canonical layout: app icon + chevron + Applications folder,
# with the app's own icon used as the DMG volume icon.
#
# Usage: bash create_dmg.sh
#
# Requires:
#   brew install create-dmg      (npm package: sindresorhus/create-dmg)

set -e

APP_NAME="Vitroscribe"
DERIVED="/tmp/vscribe_derived"
RELEASE="release"

echo "→ Building $APP_NAME (Release)..."
xcodebuild \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Release \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  -derivedDataPath "$DERIVED" \
  | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)" || true

if [ ! -d "$DERIVED/Build/Products/Release/${APP_NAME}.app" ]; then
  echo "✗ Build failed."
  exit 1
fi

echo "→ Copying .app to release/..."
mkdir -p "$RELEASE"
rm -rf "$RELEASE/${APP_NAME}.app"
cp -R "$DERIVED/Build/Products/Release/${APP_NAME}.app" "$RELEASE/"

echo "→ Creating DMG..."
rm -f "$RELEASE/${APP_NAME}.dmg"

create-dmg \
  --overwrite \
  --no-code-sign \
  --dmg-title "$APP_NAME" \
  "$RELEASE/${APP_NAME}.app" \
  "$RELEASE/"

# create-dmg names the file "AppName X.Y.dmg" — rename to canonical Vitroscribe.dmg
VERSIONED=$(ls "$RELEASE/${APP_NAME} "*.dmg 2>/dev/null | head -1)
if [ -n "$VERSIONED" ]; then
  mv "$VERSIONED" "$RELEASE/${APP_NAME}.dmg"
fi

rm -rf "$DERIVED"

echo "✓ Done: $RELEASE/${APP_NAME}.dmg"
ls -lh "$RELEASE/${APP_NAME}.dmg"
