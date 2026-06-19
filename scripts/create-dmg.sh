#!/bin/bash
set -euo pipefail

APP_NAME="record_space"
DMG_NAME="record_space"
BUILD_DIR="build/Build/Products/Release"
STAGING_DIR="build/dmg-staging"
DMG_OUTPUT="build/${DMG_NAME}.dmg"
VOL_NAME="record_space"

cd "$(dirname "$0")/.."

echo "==> Building ${APP_NAME}..."
rm -rf build
xcodebuild -project VoiceMemoBar.xcodeproj \
  -scheme VoiceMemoBar \
  -configuration Release \
  -derivedDataPath build \
  2>&1 | tail -3

APP_PATH="${BUILD_DIR}/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: Build failed — ${APP_PATH} not found."
  exit 1
fi

echo "==> Creating DMG..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_OUTPUT"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_OUTPUT"

rm -rf "$STAGING_DIR"

SIZE=$(du -h "$DMG_OUTPUT" | cut -f1 | xargs)
echo ""
echo "==> Done: ${DMG_OUTPUT} (${SIZE})"
echo "    Open the DMG and drag record_space to Applications."
