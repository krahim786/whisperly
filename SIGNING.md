# Signing & Notarization

Two paths depending on who's installing the DMG:

| Path | For | What you need | Command |
| --- | --- | --- | --- |
| **Family-share (ad-hoc)** | Yourself, family, friends | Nothing beyond Xcode | `./scripts/build-local-dmg.sh` |
| **Public release** | Anyone, anywhere on the internet | Apple Developer Program ($99/year) + setup below | `./scripts/build-dmg.sh` |

The family-share path is documented at the bottom of this file. The rest of this document covers the public-release setup.

---

## Public release — one-time setup so `scripts/build-dmg.sh` can produce a notarized, distributable Whisperly.dmg.

## Prerequisites

- **Apple Developer Program membership** ($99/year) — gets you a "Developer ID Application" certificate.
- **Xcode 16+** with command-line tools installed.
- **Your Team ID** (10-char alphanumeric) — visible at <https://developer.apple.com/account> under Membership.

## One-time setup

### 1. Install your Developer ID Application certificate

In Xcode → Settings → Accounts → select your Apple ID → **Manage Certificates…** → **+** → **Developer ID Application**. Xcode generates the cert and installs it into your login Keychain.

Verify:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

You should see one line like:

```
1) ABCDEF1234567890...  "Developer ID Application: Karim Rahim (TEAMID12)"
```

### 2. Create an app-specific password for notarization

`notarytool` doesn't accept your regular Apple ID password. Generate an app-specific password:

1. Go to <https://account.apple.com/account/manage>
2. Sign in → **App-Specific Passwords** → **+** → label it "Whisperly notarization" → save the generated password somewhere safe (it's shown once).

### 3. Store the notarytool credentials in Keychain

```bash
xcrun notarytool store-credentials "whisperly-notary" \
  --apple-id "your-apple-id@example.com" \
  --team-id "TEAMID12" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

This creates a Keychain item named `whisperly-notary` that the build script will reference. You only do this once per machine.

### 4. Set the env vars the build script reads

Either export them in your shell or copy `.env.example` → `.env`:

```bash
export WHISPERLY_TEAM_ID="TEAMID12"
export WHISPERLY_SIGNING_IDENTITY="Developer ID Application: Karim Rahim (TEAMID12)"
export WHISPERLY_NOTARY_PROFILE="whisperly-notary"
```

The script will fail loudly if any are missing.

## Building a release

```bash
./scripts/build-dmg.sh
```

What it does:

1. `xcodebuild archive` into `build/whisperly.xcarchive` with your Developer ID identity.
2. `xcodebuild -exportArchive` produces `build/Whisperly.app`.
3. `ditto -c -k --sequesterRsrc --keepParent` zips the app for notarization upload.
4. `xcrun notarytool submit … --wait` uploads, polls until ticket is issued.
5. `xcrun stapler staple` attaches the notarization ticket to the app.
6. `hdiutil create` builds `build/Whisperly.dmg` with a drag-to-Applications layout.
7. `xcrun stapler staple` on the DMG so even users who don't first-launch the app get a clean Gatekeeper experience.

The whole process takes ~2 minutes (notarization queue is the variable part).

## Common pitfalls

- **"errSecInternalComponent" during codesign** — your login Keychain is locked. `security unlock-keychain login.keychain` before re-running.
- **Notarization fails with "Invalid signature"** — usually means hardened runtime is off or there's an unsigned framework inside the .app. Run `codesign --verify --verbose --deep build/Whisperly.app` and read the output.
- **"This app is damaged" on first launch from DMG** — happens if you forget to staple. The build script does it; if you re-package manually, run `xcrun stapler staple build/Whisperly.app` and `xcrun stapler staple build/Whisperly.dmg`.
- **"Developer cannot be verified" Gatekeeper warning** — means the app isn't notarized. Check `spctl -a -vvv -t install build/Whisperly.app` — should say "accepted, source=Notarized Developer ID".

## Distributing

The output `build/Whisperly.dmg` is fully notarized and ready to ship anywhere — drop it on a website, send via AirDrop, attach to a release page. Users double-click to mount, drag to Applications, eject.

## What's not yet wired up

- **Auto-updates** — Sparkle isn't integrated yet (Day 7 deferred). When you do, you'll need to host an `appcast.xml` and EdDSA-sign each release; Sparkle's docs are good.
- **App Store distribution** — requires App Sandbox enabled, which breaks the Accessibility + cross-app paste model Whisperly relies on. Direct distribution via DMG is the right path for v1.

---

## Family-share — no Developer ID required

If you just want to send the app to family or friends and don't want to pay $99/year for the Developer Program, run:

```bash
./scripts/build-local-dmg.sh
```

This:

- Archives Release configuration with **ad-hoc signing** (`codesign --sign -`), which doesn't require any Apple Developer cert.
- Skips notarytool entirely — there's no submission to Apple.
- Produces `build/Whisperly-local.dmg` with a drag-to-Applications layout.

### What the receiving Mac sees

Because the app isn't signed with a Developer ID and isn't notarized, **Gatekeeper blocks the first launch**. Each receiving Mac has to bypass it once. Two options, both totally safe for an app you built yourself:

**Option A — System Settings (one click)**

1. Mount the DMG and drag Whisperly.app to /Applications.
2. Try to open Whisperly. macOS shows "Whisperly cannot be opened because Apple cannot check it for malicious software."
3. Click Done / Cancel.
4. System Settings → Privacy & Security → scroll to "Whisperly was blocked from use…" → **Open Anyway** → confirm with password or Touch ID.
5. macOS remembers the decision. Next launches work normally.

**Option B — Terminal (one command, instant)**

After dragging Whisperly.app to /Applications:

```bash
xattr -cr /Applications/Whisperly.app
```

That strips the "downloaded from the internet" quarantine flag. Double-click works normally afterward.

### When this approach gets awkward

- macOS gets stricter with each release; the Open Anyway path may eventually require additional clicks.
- AirDrop and iCloud Drive both add quarantine flags on transfer, so receivers always need to re-bypass even if it worked once.
- If you find yourself sharing with more than ~5 people, the $99/year Developer Program pays for itself in support time saved — a notarized DMG just opens.

For now, ad-hoc + the Open Anyway click is fine for personal use.
