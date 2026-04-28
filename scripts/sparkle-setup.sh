#!/usr/bin/env bash
#
# sparkle-setup.sh — generate the EdDSA keypair Sparkle uses to verify
# updates. Private key goes into your Keychain (read by `sign_update`
# automatically); public key is printed for you to paste into the project
# build settings.
#
# Run this once. Re-running rotates the keypair, which invalidates updates
# for anyone running an existing build with the old public key.
#
# See SPARKLE.md for the surrounding setup.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Sparkle's generate_keys binary lives inside the resolved SPM artifacts.
# Resolve packages first so we have a stable place to look.
echo "▶︎ Resolving Sparkle SPM artifacts..."
xcodebuild -project whisperly.xcodeproj -resolvePackageDependencies > /dev/null 2>&1

# Find the binary. Path differs slightly between Xcode versions; search a few.
GENERATE_KEYS=""
for candidate in \
  "$HOME/Library/Developer/Xcode/DerivedData"/whisperly-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
  "$HOME/Library/Caches/org.swift.swiftpm/security/Sparkle/Sparkle/Versions/"*/bin/generate_keys
do
  if [ -x "$candidate" ]; then
    GENERATE_KEYS="$candidate"
    break
  fi
done

if [ -z "$GENERATE_KEYS" ]; then
  cat >&2 <<EOF
✗ Could not find Sparkle's generate_keys binary in the resolved artifacts.

Try these in order:
  1. Open whisperly.xcodeproj in Xcode and let it finish resolving packages.
  2. Re-run this script.
  3. If it still doesn't find it, locate the binary manually:
       find ~/Library/Developer/Xcode/DerivedData -name generate_keys -type f
     and run it directly.

EOF
  exit 1
fi

echo "✓ Found generate_keys at: $GENERATE_KEYS"
echo ""

# Check whether a key already exists in the Keychain.
if security find-generic-password -s "https://sparkle-project.org" >/dev/null 2>&1; then
  echo "⚠ A Sparkle keypair is already stored in your Keychain."
  echo "  Re-running this script will REPLACE it, which means existing"
  echo "  installs of Whisperly built with the OLD public key will refuse"
  echo "  to install future updates."
  echo ""
  read -p "Continue and rotate the keypair? [y/N] " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted. To use the existing keypair, just run:"
    echo "  $GENERATE_KEYS -p"
    echo "to print the existing public key."
    exit 0
  fi
fi

echo "▶︎ Generating fresh EdDSA keypair..."
"$GENERATE_KEYS"

echo ""
echo "▶︎ Public key (for INFOPLIST_KEY_SUPublicEDKey in project.pbxproj):"
echo ""
"$GENERATE_KEYS" -p
echo ""
echo "Next steps (see SPARKLE.md for the full guide):"
echo "  1. Copy the public key above."
echo "  2. Open whisperly.xcodeproj/project.pbxproj in your editor."
echo "  3. Replace 'PUT_YOUR_PUBLIC_ED_KEY_HERE' with the public key (TWO"
echo "     occurrences — one for Debug, one for Release)."
echo "  4. Set INFOPLIST_KEY_SUFeedURL to your appcast URL."
echo "  5. Build a release DMG and run ./scripts/sparkle-sign.sh on it"
echo "     to get the appcast snippet."
