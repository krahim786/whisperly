# Whisperly Changelog

Per-day build log for week 1.

## Day 1 — minimum viable dictation loop

**Tag:** `day-1-complete`

The bones. Hold Right Option, speak, release, get polished text pasted at the cursor.

- Menu bar app via `MenuBarExtra` (no Dock icon, `LSUIElement = YES`)
- `KeychainService` for API key storage
- `HotkeyManager` — `NSEvent.flagsChanged` global + local monitor for keyCode 61
- `AudioRecorder` — `AVAudioEngine` + `AVAudioConverter` → 16 kHz mono PCM WAV
- `GroqClient` — multipart POST to Whisper Large v3 Turbo
- `HaikuClient` — JSON POST with prompt-cached system block, `claude-haiku-4-5-20251001`
- `ContextDetector.frontmostAppName()` via NSWorkspace
- `TextInserter` — pasteboard snapshot + `CGEvent` ⌘V + restore
- `AppState` phase machine: idle → recording → transcribing → cleaning → pasting → error
- `APIKeysSettingsView` for paste-and-save key flow
- `DictationPrompt` with `{DICTIONARY_JSON}` placeholder for later days

## Day 2 — HUD, double-tap, audio polish

**Tag:** `day-2-complete`

Made it feel like a real app. Visual feedback, both activation modes, robust audio handling.

- `HUDPanel` — borderless non-activating `NSPanel`, `.canJoinAllSpaces`, `ignoresMouseEvents`, can't become key/main → never steals focus from the paste target
- `HUDView` — pulse-animated state pill, 20-bar live amplitude visualizer
- `HUDController` — observes `AppState.phase` + `HotkeyConfig.showHUD`, repositions on screen-parameter changes
- `HotkeyConfig` — UserDefaults-backed `ObservableObject` (mode, key, HUD, chimes)
- Double-tap toggle mode (two presses within 400 ms start; next press stops)
- Configurable hotkey key (Right Option / Cmd / Shift / Control / Fn)
- `SoundPlayer` — Tink/Pop start/stop chimes, optional
- VAD leading-silence trim (8-buffer ring, 0.012 RMS gate)
- VAD trailing-silence trim (2.5 s gate, preserves mid-utterance pauses)
- 60 s max-recording safeguard
- `noSpeechDetected` error → "No speech detected" HUD flash
- Per-buffer RMS publisher feeding the HUD bars
- Tabbed Settings (General / Hotkey / API Keys)

## Day 3 — history + selection-aware editing

**Tag:** `day-3-complete`

The killer feature. Two big systems landed together.

- GRDB.swift 6.29.3 SPM dependency
- `HistoryStore` with one migration that creates the `history` table, the timestamp index, the `history_fts` FTS5 virtual table, and three triggers keeping FTS in sync on insert/update/delete
- FTS5 prefix-match search + date-range filtering
- Retention sweep at launch
- JSON export via `NSSavePanel`
- History window (Table, search, filter, copy/repaste/delete) opened via ⌘Y
- `ContextDetector.getSelectedText()` reads `kAXSelectedTextAttribute` with a 0.25 s AX timeout
- `AccessibilityChecker` wraps trust + first-run prompt + deep link to Privacy & Security → Accessibility
- `EditPrompt` per spec
- `HaikuClient.editSelection(...)` shares the completion path with `cleanup`
- `AppState` reads selection synchronously at hotkey press, routes to edit mode, surfaces "Editing selection" subtitle in HUD
- Async history insert post-paste so the user is never blocked

### Day 3.5 — fix

**Commit:** `0d750ae`

`scheduleMaxLengthGuard` was spawning a detached `Task` that wasn't cancelled on stop. A 5 s recording followed within 60 s by another recording could see the old guard fire mid-way through the new cycle, truncating the audio file ("cuts off after a few words"). Fixed by holding the Task in a property and cancelling it both on every new schedule and on `endRecordingOnQueue`.

## Day 4 — snippets, command mode, personal dictionary

**Tag:** `day-4-complete`

Three intelligence features. Snippets bypass the LLM; command mode reuses Haiku with a dedicated prompt; the dictionary biases both Whisper and Haiku.

- `Snippet` model + `SnippetStore` (JSON in Application Support)
- `SnippetMatcher` — case-insensitive, trims trailing punctuation, accepts optional "insert" / "type" prefix; matches bypass the LLM entirely
- `SnippetsSettingsView` master/detail editor
- `CommandPrompt` per spec + `looksLikeCommand` detector (prefix + separator)
- `HaikuClient.command(...)` shared completion path
- `DictionaryEntry` model with `source: manual|learned` + `confirmedCount`
- `DictionaryStore` ObservableObject, JSON-backed entries + suggestions
- All three system prompts (Dictation/Edit/Command) take a `dictionaryJSON` parameter; AppState injects the current dictionary so the cached prefix sees the user's vocabulary
- `GroqClient.transcribe` accepts `biasingTerms`; up to 20 top terms passed as Whisper's `prompt` parameter for STT-level bias
- `DictionaryLearner` — token-diff cleaned vs corrected; auto-promotes to `learned` after 3 confirmations
- `HistoryWindowView` right-click → "Edit cleaned text…" sheet, on save runs the learner
- `DictionarySettingsView` with entries table, add bar, suggestion chips
- Menu-bar dropdown shows pending suggestion count

## Day 5 — onboarding, analytics, stats, polish

**Tag:** `day-5-complete`

First-run experience and the data + visualization to make Whisperly feel like a habit.

- `OnboardingWindow` paged container with progress bar
- 5 steps: Welcome → Permissions → API Keys → Hotkey → First Dictation
- Permissions step has a 1 Hz AX-trust poller (since macOS doesn't notify)
- API Keys step runs Groq (`/v1/models`) + Anthropic (1-token "ping") validations in parallel
- First-launch trigger + reopen via Settings → General → Re-run onboarding
- `AnalyticsTracker` derives summary, daily points, top apps, hour-of-day from history; refreshes on `changeSubject`
- `HistoryStore.analyticsRows()` slim projection — no full text columns
- Stats window with 6 stat cards + 4 Swift Charts (words/day, WPM trend with typing-baseline `RuleMark`, top apps, time-of-day) + baseline slider
- Menu bar dropdown shows today/streak/all-time/saved inline
- `LaunchAtLoginService` via `SMAppService.mainApp`
- `GroqClient.validate` + `HaikuClient.validate` for onboarding gating
- General settings reorganized into Startup / Visual / Audio / Onboarding sections

## Day 6 — robustness

**Tag:** `day-6-complete`

Hardens for real-world use. Items prioritized by impact: AX fallback first, the rest deferred.

- `ContextDetector.getSelectedTextViaCopy()` — ⌘C-fallback selection capture for Electron / web inputs (Slack, Discord, Cursor, VS Code)
- AppState fires the fallback in parallel with mic startup at hotkey press, awaits before pipeline routes
- `NSWorkspace.willSleep` / `sessionDidResignActive` / `AVAudioEngineConfigurationChange` observers cancel recording cleanly with a HUD message
- `AudioRecorder.maxLengthHits` Combine signal → "Recording capped at 60s" HUD
- `AppState.haikuWithRetry` retries once on `rateLimited` after 1 s; second failure goes through the existing fallback (paste raw transcript)
- HUD "Polish skipped — <reason>" warning on Haiku fallback
- `FileLogger` — daily-rotated logs in `~/Library/Logs/Whisperly/`, off by default, toggled by `HotkeyConfig.verboseLogging`
- General settings Diagnostics section with the toggle + Reveal in Finder

Skipped (low-value, high-complexity): long-dictation chunking past 60 s, hotkey-conflict detection.

## Day 7 — ship-prep

**Tag:** `day-7-complete`

About / Help / Acknowledgements, README rewrite, Privacy Policy, signing setup, DMG build script.

- `AboutView` window with version, links, GitHub
- `AcknowledgementsView` listing GRDB + license + cloud services note
- `HelpCheatSheetView` — keyboard shortcuts + modes + tips
- App-level `.commands` overrides Help (⌘?) and About menu items
- Menu bar dropdown gains About + Help entries
- README rewritten as a feature tour + setup + troubleshooting + FAQ
- `PRIVACY.md` — full disclosure of what leaves the machine and where
- `CHANGELOG.md` — this file
- `SIGNING.md` — Developer ID + notarytool one-time setup
- `scripts/build-dmg.sh` — archive → export → notarize → staple → DMG
- Final polish on copy and animation timings
