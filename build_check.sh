#!/bin/bash
set -e
APP="Vitroscribe"
DERIVED="build_derived"
RELEASE="release"
mkdir -p "$DERIVED"
xcodebuild \
  -project "${APP}.xcodeproj" \
  -scheme "${APP}" \
  -configuration Release \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  -derivedDataPath "$DERIVED" \
  2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" \
       | head -20 \
  > "$DERIVED/result.txt" 2>/dev/null || true
# Copy app if build succeeded
if [ -d "$DERIVED/Build/Products/Release/${APP}.app" ]; then
  rm -rf "$RELEASE/${APP}.app"
  cp -R "$DERIVED/Build/Products/Release/${APP}.app" "$RELEASE/"
  echo "BUILD_OK" >> "$DERIVED/result.txt"
else
  echo "BUILD_FAILED" >> "$DERIVED/result.txt"
fi
