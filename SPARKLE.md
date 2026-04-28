# Sparkle Auto-Update — Setup

Whisperly ships with [Sparkle 2.x](https://sparkle-project.org) wired in. Each release you build can be advertised via an `appcast.xml` that the app polls daily; users get a "new version available" prompt without anyone AirDropping a new DMG. This document is the one-time setup so the wiring actually delivers updates.

There are three pieces:

1. An **EdDSA keypair** for signing each release (private key stays on your machine; public key gets baked into every build).
2. A place to **host your `appcast.xml` and the DMGs** it references.
3. A **per-release signing step** that produces the DMG signature Sparkle verifies.

## 1. Generate the keypair (one-time)

Sparkle ships a `generate_keys` CLI inside its SPM artifacts. The simplest way:

```bash
./scripts/sparkle-setup.sh
```

That:

- Locates `generate_keys` inside the resolved SPM checkout.
- Generates a fresh EdDSA keypair.
- Stores the private key in your macOS Keychain under `https://sparkle-project.org` (Sparkle's `sign_update` CLI looks here automatically).
- Prints the public key — you copy it into the project's build settings.

After running it, paste the printed public key into `project.pbxproj` (replacing `PUT_YOUR_PUBLIC_ED_KEY_HERE`) — search for `INFOPLIST_KEY_SUPublicEDKey`. Two occurrences (Debug + Release).

## 2. Pick a hosting URL

Easiest: **GitHub Releases**.

1. Create a public repo (or use the one you already host the source in).
2. Each version: cut a release, attach the DMG as an asset, attach `appcast.xml` as an asset.
3. Set `INFOPLIST_KEY_SUFeedURL` in the build settings to:
   ```
   https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml
   ```

   GitHub's `latest/download` redirect always points to the most recent release, so the appcast URL never changes — only its content does.

Alternative hosts: any HTTPS-served folder (Cloudflare R2, S3 bucket, your own domain). Sparkle just needs to fetch a static `appcast.xml`.

## 3. Cut a release

After making changes:

1. **Bump the version** — Xcode → target whisperly → General → Version (e.g. `1.0` → `1.1`). The Build number can stay or bump too.
2. **Build a signed DMG**:
   - Family-share path: `./scripts/build-local-dmg.sh`
   - Public-release path (Developer ID + notarized): `./scripts/build-dmg.sh`
3. **Sign the DMG with Sparkle**:
   ```bash
   ./scripts/sparkle-sign.sh build/Whisperly-local.dmg
   ```
   This prints an `<enclosure>` snippet you paste into `appcast.xml`.
4. **Update `appcast.xml`** with a new `<item>` block that has the snippet's `length`, `sparkle:edSignature`, and `sparkle:version`.
5. **Upload** the DMG and the updated `appcast.xml` to your release.

## What the user experiences

- Whisperly polls `SUFeedURL` every 24h (configurable via `SUScheduledCheckInterval`).
- On a new version: Sparkle shows its standard "Whisperly X.Y is available — Update" alert.
- User clicks Update → Sparkle downloads the DMG → verifies the EdDSA signature → installs over the old app → relaunches.
- For ad-hoc-signed builds (family-share path): Sparkle still verifies the EdDSA signature, but Gatekeeper may re-prompt on first launch of the updated app. Tell family members to do the System Settings → Open Anyway dance once after each update.
- For Developer ID + notarized builds: just works.

## When Sparkle isn't fully wired up yet

Settings → General → Updates shows a **⚠ "feed URL is still a placeholder"** warning whenever `SUFeedURL` is empty or contains `example.com` / `PUT_YOUR`. The "Check for Updates…" menu items still appear (so the path is testable) — they'll just fail immediately because the feed isn't hosted yet. Wire steps 1-2 above and the warning goes away.

## Common pitfalls

- **EdDSA signature mismatch** at install time: usually means the `appcast.xml` entry's `sparkle:edSignature` doesn't match the DMG that was actually uploaded. Re-run `sparkle-sign.sh` against the *exact* DMG file you'll upload.
- **`SUPublicEDKey` mismatch**: rebuilding the app with a different public key invalidates updates for everyone on the old key. Don't rotate the keypair unless you're starting fresh.
- **Quarantine on the updated app**: Sparkle 2.x removes quarantine on the new app bundle automatically after install. If you see the "Whisperly cannot be opened" dialog *after* an auto-update, the user did something unusual (e.g. moved /Applications). Tell them to drag a fresh DMG.
- **Looks for updates on every launch?** Likely `SUEnableAutomaticChecks = NO` somewhere or your `lastUpdateCheckDate` keeps resetting (sandbox container being wiped). Whisperly is unsandboxed so this shouldn't happen.

## When NOT to use Sparkle

If you only ever distribute by hand to ~5 family members AND your release cadence is <1 per month, Sparkle is overkill — a "drop a fresh DMG in iCloud Drive" workflow works fine. The setup pays off when:

- Family / users grow past the small group you can AirDrop to manually
- Update cadence picks up (you're shipping fixes weekly)
- You want the option to push a hotfix without re-explaining the install dance
