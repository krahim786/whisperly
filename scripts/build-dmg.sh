#!/usr/bin/env bash
#
# build-dmg.sh — archive, sign, notarize, and package Whisperly into a DMG.
#
# Reads from environment:
#   WHISPERLY_TEAM_ID         e.g. "TEAMID12"
#   WHISPERLY_SIGNING_IDENTITY e.g. "Developer ID Application: Karim Rahim (TEAMID12)"
#   WHISPERLY_NOTARY_PROFILE   e.g. "whisperly-notary" (stored via `xcrun notarytool store-credentials`)
#
# See SIGNING.md for one-time setup.

set -euo pipefail

# --- preflight ---

require_var() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "✗ Required env var $name is not set." >&2
    echo "  See SIGNING.md → 'Set the env vars the build script reads'." >&2
    exit 1
  fi
}

require_var WHISPERLY_TEAM_ID
require_var WHISPERLY_SIGNING_IDENTITY
require_var WHISPERLY_NOTARY_PROFILE

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

PROJECT="whisperly.xcodeproj"
SCHEME="whisperly"
CONFIGURATION="Release"
BUILD_DIR="$PROJECT_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/whisperly.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/whisperly.app"
ZIP_PATH="$BUILD_DIR/Whisperly-notarize.zip"
DMG_PATH="$BUILD_DIR/Whisperly.dmg"
DMG_STAGING="$BUILD_DIR/dmg-staging"

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$DMG_STAGING" "$ZIP_PATH" "$DMG_PATH"

# --- 1. archive ---

echo "▶︎ Archiving..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$WHISPERLY_SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$WHISPERLY_TEAM_ID" \
  archive | xcbeautify || xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$WHISPERLY_SIGNING_IDENTITY" \
  DEVELOPMENT_TEAM="$WHISPERLY_TEAM_ID" \
  archive

# --- 2. export ---

EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${WHISPERLY_TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>${WHISPERLY_SIGNING_IDENTITY}</string>
</dict>
</plist>
EOF

echo "▶︎ Exporting..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

if [ ! -d "$APP_PATH" ]; then
  echo "✗ Expected app at $APP_PATH but it doesn't exist." >&2
  exit 1
fi

# --- 3. zip for notarization ---

echo "▶︎ Zipping for notarization..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

# --- 4. notarize ---

echo "▶︎ Submitting to notarytool (will wait for ticket)..."
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$WHISPERLY_NOTARY_PROFILE" \
  --wait

# --- 5. staple the .app ---

echo "▶︎ Stapling .app..."
xcrun stapler staple "$APP_PATH"

# --- 6. build the DMG ---

echo "▶︎ Building DMG..."
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
  -volname "Whisperly" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "$DMG_PATH"

# --- 7. sign and staple the DMG ---

echo "▶︎ Signing DMG..."
codesign --sign "$WHISPERLY_SIGNING_IDENTITY" --timestamp "$DMG_PATH"

echo "▶︎ Submitting DMG for notarization..."
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$WHISPERLY_NOTARY_PROFILE" \
  --wait

echo "▶︎ Stapling DMG..."
xcrun stapler staple "$DMG_PATH"

# --- done ---

echo ""
echo "✓ $DMG_PATH"
echo ""
spctl -a -vvv -t install "$APP_PATH" 2>&1 || true
echo ""
ls -lh "$DMG_PATH"
