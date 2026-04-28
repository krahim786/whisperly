#!/usr/bin/env bash
#
# sparkle-sign.sh — sign a built DMG with the Sparkle EdDSA keypair stored
# in Keychain, and print an <enclosure> snippet ready to paste into
# appcast.xml.
#
# Usage:
#   ./scripts/sparkle-sign.sh build/Whisperly-local.dmg
#
# Requires that scripts/sparkle-setup.sh has been run once to generate the
# keypair. See SPARKLE.md.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <path-to-dmg>" >&2
  exit 1
fi

DMG="$1"
if [ ! -f "$DMG" ]; then
  echo "✗ DMG not found: $DMG" >&2
  exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Locate Sparkle's sign_update binary (same search pattern as setup).
SIGN_UPDATE=""
for candidate in \
  "$HOME/Library/Developer/Xcode/DerivedData"/whisperly-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update \
  "$HOME/Library/Caches/org.swift.swiftpm/security/Sparkle/Sparkle/Versions/"*/bin/sign_update
do
  if [ -x "$candidate" ]; then
    SIGN_UPDATE="$candidate"
    break
  fi
done

if [ -z "$SIGN_UPDATE" ]; then
  echo "✗ Could not find Sparkle's sign_update binary." >&2
  echo "  Run ./scripts/sparkle-setup.sh once to set things up." >&2
  exit 1
fi

# Pull version + build from the project so the snippet is ready to paste.
PLIST="$PROJECT_ROOT/whisperly.xcodeproj/project.pbxproj"
VERSION=$(grep -m1 'MARKETING_VERSION = ' "$PLIST" | sed 's/[^0-9.]*//g' | head -1 || echo "1.0")
BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PLIST" | sed 's/[^0-9]*//g' | head -1 || echo "1")
SIZE=$(stat -f%z "$DMG")
FILENAME=$(basename "$DMG")
TODAY=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")

echo "▶︎ Signing $DMG with Sparkle EdDSA key..."
SIGN_OUTPUT=$("$SIGN_UPDATE" "$DMG")
# sign_update prints e.g.  sparkle:edSignature="..." length="N"
echo "✓ Signed."
echo ""
echo "Paste this <item> into your appcast.xml (after editing the URL,"
echo "release notes link, and version if you bumped it):"
echo ""
cat <<EOF
        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${TODAY}</pubDate>
            <sparkle:version>${BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure
                url="https://YOUR-HOST/path/to/${FILENAME}"
                ${SIGN_OUTPUT}
                type="application/octet-stream"
            />
        </item>
EOF
