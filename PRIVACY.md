# Whisperly Privacy

This document describes exactly what Whisperly does with your data. There are no servers between you and the providers — Whisperly is a desktop client, not a backend service.

## What leaves your machine, and where it goes

| Data | Sent to | Endpoint | Why |
| --- | --- | --- | --- |
| Recorded audio (16 kHz mono PCM WAV) | **Groq** | `https://api.groq.com/openai/v1/audio/transcriptions` | Speech-to-text via Whisper Large v3 Turbo |
| Top 20 personal-dictionary terms | **Groq** | Same endpoint, as the optional `prompt` parameter | Vocabulary biasing so proper nouns transcribe correctly |
| Raw transcript + frontmost app name | **Anthropic** | `https://api.anthropic.com/v1/messages` | Cleanup / edit / command via Claude Haiku 4.5 |
| Selected text (edit mode only) | **Anthropic** | Same endpoint, in the message body | The selection is what's being rewritten |
| Personal dictionary JSON (cached) | **Anthropic** | Same endpoint, inside the system block | Preserves exact spelling & casing |

Whisperly never collects, transmits, or stores any data on a Whisperly-controlled server. There is no Whisperly backend, no telemetry, no analytics provider, no crash reporter.

## What stays local

| Data | Where |
| --- | --- |
| API keys | macOS Keychain, service `com.karim.whisperly` |
| History (every dictation) | `~/Library/Application Support/com.karim.whisperly/whisperly.sqlite3` |
| Snippets | `~/Library/Application Support/com.karim.whisperly/snippets.json` |
| Personal dictionary | `~/Library/Application Support/com.karim.whisperly/dictionary.json` |
| Pending dictionary suggestions | `~/Library/Application Support/com.karim.whisperly/dictionary_suggestions.json` |
| Settings (mode, key, toggles, retention, baseline WPM) | `~/Library/Preferences/com.karim.whisperly.plist` (UserDefaults) |
| Verbose logs (only if enabled) | `~/Library/Logs/Whisperly/whisperly-YYYY-MM-DD.log` |
| Temporary WAV files during transcription | `~/Library/Containers/com.karim.whisperly/Data/tmp/whisperly-<UUID>.wav` (deleted right after each transcription; older orphans purged on launch) |

## What's never written to verbose logs

When you enable verbose file logging (Settings → General → Diagnostics), the logs include hotkey events, mode resolution, network results, and cache-hit counts — but **not** API keys, transcripts, cleaned text, or selected text. You can attach a verbose log to an issue without leaking content.

## Provider data-handling

Whisperly's behavior with respect to the providers is what the providers say it is. The summaries below are accurate as of the v1 build but you should review the providers' current policies if data residency matters to you.

- **Groq** — current Groq API does not train on customer data and retains transcription audio per their published retention policy. See <https://groq.com/privacy>.
- **Anthropic** — Claude API does not train on inputs unless you opt in. Data retention is per Anthropic's published policy. See <https://www.anthropic.com/legal/privacy>.

If your environment requires data not leaving your machine, Whisperly is not currently the right tool — there's no on-device-only mode in v1.

## Permissions Whisperly requests

| Permission | Why |
| --- | --- |
| **Microphone** | Records your voice while you hold the hotkey |
| **Accessibility** | Two reasons: (a) reading `kAXSelectedTextAttribute` from the focused element to detect edit mode; (b) posting synthesized ⌘V keystrokes to paste at the cursor |
| **Apple Events** (declared via `NSAppleEventsUsageDescription`) | Detecting the frontmost app for context-aware formatting |

Whisperly does **not** request: Camera, Photos, Contacts, Calendar, Reminders, Location, Files outside `~/Library/Application Support/com.karim.whisperly/`, Full Disk Access, or Input Monitoring.

## Deletion

- **Clear history** — Settings → History → Clear All… (with confirmation). This deletes every row in the SQLite database.
- **Clear keys** — Settings → API Keys → clear and save empty fields, or delete the items directly via Keychain Access.app under service "com.karim.whisperly".
- **Wipe everything Whisperly stores** — quit the app and run:
  ```bash
  rm -rf ~/Library/Application\ Support/com.karim.whisperly
  rm -rf ~/Library/Logs/Whisperly
  defaults delete com.karim.whisperly
  ```
  Then delete the API keys from Keychain Access.

## Network destinations

Whisperly only ever opens HTTPS connections to:

- `api.groq.com` (transcription)
- `api.anthropic.com` (cleanup / edit / command)
- `console.groq.com` and `console.anthropic.com` (links opened in your browser when you click "Get an API key" — no Whisperly request, just a URL handed to your browser)

There are no analytics, crash-reporter, or update-check connections in v1. (Auto-updates are not yet wired up; if added, Sparkle's update feed would be hosted by you, not by Whisperly.)
