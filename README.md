# Whisperly

A Wispr Flow-style voice dictation app for macOS. Hold a hotkey, speak, and Whisperly transcribes + cleans your speech with cloud AI (Groq Whisper Large v3 Turbo + Claude Haiku 4.5) and pastes polished text into whatever app you're in — with selection-aware editing, voice commands, snippets, a personal dictionary, and full searchable history.

Status: feature-complete week-1 build. Days 1–7 done.

## What it does

| Mode | How to trigger | What happens |
| --- | --- | --- |
| **Dictation** | Nothing selected, hold the hotkey, speak | Whisperly transcribes via Groq, polishes with Haiku (context-aware per app), pastes at the cursor |
| **Edit** | Text selected, hold the hotkey, speak an instruction | Selection is rewritten in place. Works in native apps via Accessibility; falls back to ⌘C in Electron / web inputs |
| **Command** | Speech starts with "bullet list:", "email:", "code:", "summarize", "table", "casual", "formal", "translate to X" | Formatted output replaces standard cleanup |
| **Snippet** | Speech matches a snippet trigger (optionally prefixed with "insert" / "type") | Direct expansion — no LLM call |

Everything happens in a non-activating HUD that doesn't steal focus from the app you're typing into. Every dictation is logged to a searchable SQLite + FTS5 history. A personal dictionary biases both Whisper STT and Haiku cleanup so your vocabulary (proper nouns, product names, identifiers) is preserved exactly. Manual corrections in the History window feed a learner that auto-promotes terms after 3 confirmations.

## Setup

1. **API keys** — get them at <https://console.groq.com/keys> and <https://console.anthropic.com/settings/keys>. Both keys are stored in your macOS Keychain.
2. **Open `whisperly.xcodeproj` in Xcode 16+** (project uses filesystem-synchronized groups, so all source files under `whisperly/` are auto-included).
3. **Build & run** (⌘R). Whisperly launches as a menu bar item — no Dock icon, no main window. The first run opens an onboarding flow.
4. **Onboarding walks you through**: welcome → permissions (Microphone + Accessibility) → API keys (with live validation) → hotkey choice (mode + key) → guided first dictation. Takes about 90 seconds.
5. **Try it**: focus any text field, hold Right Option (default), speak a sentence, release. Polished text appears at your cursor in 1–3 seconds.

## Settings

Six tabs (⌘,):

- **General** — launch at login, HUD toggle, start/stop chimes, re-run onboarding, verbose log toggle
- **Hotkey** — hold vs double-tap, key chooser (Right Option / Cmd / Shift / Control / Fn)
- **Snippets** — master/detail editor with use-count
- **Dictionary** — manual entries, phonetic hints, learner suggestion chips
- **History** — retention days, clear, export as JSON
- **API Keys** — Groq + Anthropic, stored in Keychain

## Windows

- **Menu bar dropdown** — current state, today/streak/all-time analytics inline, pending dictionary suggestions
- **History** (⌘Y) — searchable Table with date / app / mode / preview, double-click to re-paste, right-click to copy/edit/delete
- **Stats** — Swift Charts dashboard: words/day, WPM trend with typing-baseline overlay, top apps, time-of-day, time saved
- **Settings** (⌘,) — six tabs, listed above
- **Help** (⌘?) — keyboard shortcut cheat sheet
- **About** — version, links, acknowledgements

## Architecture

```
HotkeyManager  ──events──▶  AppState  ──▶  AudioRecorder  ──WAV──▶  GroqClient
       (NSEvent flagsChanged       (state machine)         (16kHz PCM)        (Whisper Large v3 Turbo)
        global+local monitor,                                                         │
        configurable key, hold/                            transcript                 ▼
        toggle modes)                                          │              raw text + dict
                                                               ▼                      │
                                                        ContextDetector               ▼
                                                        (frontmost app +       SnippetMatcher ────► paste (bypass LLM)
                                                         AX selection +                │
                                                         ⌘C fallback)                  ▼
                                                                              CommandPrompt.detect
                                                                                       │
                                                                                       ▼
                                                                                HaikuClient
                                                                                .cleanup / .editSelection / .command
                                                                                (prompt-cached system block; dict injected)
                                                                                       │
                                                                                       ▼
                                                                                TextInserter
                                                                                (clipboard snapshot + ⌘V + restore)
                                                                                       │
                                                                                       ▼
                                                                                HistoryStore (GRDB + FTS5)
                                                                                AnalyticsTracker (derived)
                                                                                DictionaryLearner (token-diff)
```

## Privacy

Whisperly sends your recorded audio to Groq for transcription, and the resulting transcript + frontmost app name to Anthropic for cleanup. **No Whisperly servers in the middle.** API keys live in your Keychain. History stays in `~/Library/Application Support/com.karim.whisperly/whisperly.sqlite3`. See [PRIVACY.md](PRIVACY.md) for details.

## Building a release

See [SIGNING.md](SIGNING.md) for one-time Developer ID + notarization setup, then:

```bash
./scripts/build-dmg.sh
```

That archives, signs with your Developer ID, exports, notarizes, staples, and produces a `Whisperly.dmg` in `build/`.

## Troubleshooting

- **Hotkey doesn't trigger** — System Settings → Privacy & Security → Accessibility — make sure Whisperly is enabled. Modifier-key hotkeys are detected via `NSEvent.flagsChanged`, which doesn't need Input Monitoring permission separately.
- **Paste doesn't appear in app X** — that app probably blocks synthesized keystrokes. Toggle Whisperly off and back on in Privacy & Security → Accessibility, then relaunch.
- **Edit mode doesn't work in Slack / Discord / Cursor** — these are Electron, so Accessibility selection-reading fails silently. Whisperly automatically falls back to ⌘C; if the app blocks that too, you'll get plain dictation instead.
- **"Cuts off after a few words"** — fixed in Day 3.5 (stale max-recording guard). If you see it again, file an issue with verbose logs (Settings → General → Diagnostics → enable, reproduce, then "Reveal log folder in Finder").
- **`cache_create:0 cache_read:0` in console** — your system prompt is below Anthropic's 1024-token cache threshold. Add ~10 dictionary entries and caching kicks in automatically.

## What's not in the v1.0 build

- App Store distribution (would require sandboxing — Accessibility + cross-app paste don't work cleanly under sandbox)
- Streaming transcription (Groq batch is fast enough)
- Local-only mode (no on-device Whisper option yet)
- iOS / iPad client
- Cloud sync of history / dictionary / snippets across machines
- Sparkle auto-update — wired up at SPM level only; no update feed yet

## Day-by-day build log

See [CHANGELOG.md](CHANGELOG.md) for the per-day diff.

## License

Private project. Acknowledgements for open-source dependencies are bundled in the app's About → Acknowledgements panel and listed in [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).
