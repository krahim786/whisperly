# Whisperly

A Wispr Flow-style voice dictation app for macOS. Hold a hotkey, speak, and Whisperly transcribes + cleans your speech with cloud AI (Groq Whisper + Claude Haiku) and pastes polished text into whatever app you're in.

## Status

**Day 1 of 7** — minimum viable dictation loop only. Hold Right Option, speak, release, get clean text pasted at the cursor.

## Setup

1. **Get a Groq API key** at <https://console.groq.com/keys>.
2. **Get an Anthropic API key** at <https://console.anthropic.com/settings/keys>.
3. **Open `whisperly.xcodeproj` in Xcode 16+** (the project uses filesystem-synchronized groups, so all files under `whisperly/` are automatically included in the build target — no manual file dragging needed).
4. **Build & Run** (⌘R). The app launches as a menu bar item — no Dock icon (`LSUIElement = YES`).
5. **Grant Microphone permission** when macOS prompts you.
6. **Grant Accessibility permission**: the first time you try to dictate, macOS will block the synthesized ⌘V keystroke. Open *System Settings → Privacy & Security → Accessibility* and enable **whisperly**. (You may need to relaunch the app afterward.)
7. **Click the menu bar icon → Settings…** (or press ⌘,) and paste your Groq + Anthropic API keys, then click **Save**.
8. **Try it**: focus any text field (TextEdit, Mail, Slack, etc.), hold **Right Option**, speak a sentence, release. Within ~1–3 seconds, polished text should appear at your cursor.

## How it works

```
Right Option ↓  →  AVAudioEngine records 16 kHz mono WAV
Right Option ↑  →  Groq Whisper transcribes
                →  Claude Haiku 4.5 cleans (with prompt caching)
                →  Saved clipboard, paste via ⌘V, restored clipboard
```

The Haiku system prompt adapts to the frontmost app: Slack-style casual, Mail-style formal, code-aware in editors, etc. See `whisperly/Prompts/DictationPrompt.swift`.

## Day 1 architecture

| File | Purpose |
| --- | --- |
| `whisperly/whisperlyApp.swift` | `@main`, MenuBarExtra, Settings scene, owns all services. |
| `whisperly/AppState.swift` | State machine: idle → recording → transcribing → cleaning → pasting. |
| `whisperly/Services/HotkeyManager.swift` | Global + local NSEvent monitors for Right Option (keyCode 61). |
| `whisperly/Services/AudioRecorder.swift` | AVAudioEngine + AVAudioConverter → 16 kHz mono PCM WAV. |
| `whisperly/Services/GroqClient.swift` | Multipart POST to `whisper-large-v3-turbo`. |
| `whisperly/Services/HaikuClient.swift` | JSON POST to `claude-haiku-4-5-20251001` with system-block prompt caching. |
| `whisperly/Services/ContextDetector.swift` | `NSWorkspace.frontmostApplication`. |
| `whisperly/Services/TextInserter.swift` | Save clipboard → write text → CGEvent ⌘V → restore clipboard. |
| `whisperly/Services/KeychainService.swift` | Generic password items under service `com.karim.whisperly`. |
| `whisperly/UI/Settings/APIKeysSettingsView.swift` | Two SecureField rows + Save button. |
| `whisperly/Prompts/DictationPrompt.swift` | The cached system prompt (with `{DICTIONARY_JSON}` placeholder). |

## Known limitations (Day 1)

These are intentionally deferred — see `whisperly-spec.md` for the per-day plan.

- No floating HUD window (Day 2)
- No double-tap toggle hotkey mode (Day 2)
- No voice-activity-based audio trimming (Day 2)
- No history (Day 3)
- No selection-aware editing (Day 3)
- No snippets / personal dictionary / command mode (Day 4)
- No onboarding flow (Day 5)
- No code signing / notarization / DMG (Day 7)

## Verifying prompt caching

After your second consecutive dictation within ~5 minutes, the Haiku log line in Console will show `cache_read:N` instead of `cache_create:N`. Open Console.app, filter by subsystem `com.karim.whisperly`, and watch for `Haiku cleanup … cache_read:…` messages.

## Privacy

Whisperly sends:
- Your recorded audio to Groq's transcription API (<https://api.groq.com>).
- The raw transcript + frontmost app name to Anthropic's messages API (<https://api.anthropic.com>).

API keys are stored in your macOS Keychain. No telemetry, no third-party analytics.
