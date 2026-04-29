import AppKit
import AVFoundation
import Combine
import Foundation
import os
import SwiftUI

/// Single ObservableObject that owns the dictation state machine and the
/// references to all collaborators.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case cleaning
        case pasting
        case error(String)
    }

    /// Internal mode for the in-flight cycle. Captured at hotkey press for
    /// `.edit`; resolved post-transcription for snippet vs command vs dictation.
    private enum DictationMode: Equatable {
        case dictation
        case edit(selection: String)
    }

    @Published private(set) var phase: Phase = .idle

    @Published private(set) var amplitudeHistory: [Float] = []
    private let amplitudeHistorySize = 24

    @Published private(set) var modeDisplay: String?

    /// Live partial transcript from on-device speech recognition. Updated
    /// continuously while phase == .recording; cleared on phase change.
    /// HUD reads this directly. Empty string when no preview is available
    /// (permission denied, locale unsupported, etc.).
    @Published private(set) var liveTranscript: String = ""

    /// Whether the OS currently trusts Whisperly for Accessibility (and,
    /// transitively, for synthesized ⌘V paste). On the ad-hoc-signed
    /// family-share build this gets revoked silently every Sparkle update —
    /// the menu UI watches this flag to surface a banner asking the user
    /// to re-grant. Refreshed on launch, on every app-becomes-active event,
    /// and whenever TextInserter notices a paste-time untrusted state.
    @Published private(set) var isAccessibilityTrusted: Bool = AccessibilityChecker.isTrusted

    /// Tracks whether we've already shown the one-shot NSAlert for this
    /// app session. Reset on every fresh launch (intentionally NOT persisted
    /// to UserDefaults — every launch should re-warn until granted).
    private var hasShownAccessibilityAlertThisSession = false

    private let minimumHoldDuration: TimeInterval = 0.2

    private let logger = Logger(subsystem: "com.karim.whisperly", category: "AppState")

    private let hotkey: HotkeyManager
    private let recorder: AudioRecorder
    private let groq: GroqClient
    private let haiku: HaikuClient
    private let context: ContextDetector
    private let inserter: TextInserter
    private let sound: SoundPlayer
    private let history: HistoryStore?
    private let snippets: SnippetStore
    private let dictionary: DictionaryStore
    private let config: HotkeyConfig
    private let speech = SpeechRecognizer()
    private let local = LocalTranscriber()
    private let actionMenu: ActionMenuController

    private var cancellables = Set<AnyCancellable>()
    private var pressedAt: Date?
    private var inFlightTask: Task<Void, Never>?

    /// Mode for the cycle currently in flight. Set on press, consumed on pipeline completion.
    private var currentMode: DictationMode = .dictation

    /// True if Shift was held at the moment of press OR added at any point
    /// while the hotkey was still held. Means "show me the action menu after
    /// transcription instead of auto-cleaning". Once true within a press
    /// window, stays true even if Shift is released early.
    private var wantsActionMenu: Bool = false

    /// Local + global flagsChanged monitors active only while the hotkey is
    /// held — they set `wantsActionMenu = true` if Shift becomes held mid-
    /// recording, and update the HUD subtitle so the user gets visual
    /// confirmation. Installed in onHotkeyPressed, torn down on release /
    /// cancel / audio interruption.
    private var shiftMonitorLocal: Any?
    private var shiftMonitorGlobal: Any?

    /// Async task for the Cmd+C selection fallback, in case AX selection-reading
    /// fails (e.g. Electron). Awaited before the pipeline routes to edit/dictation.
    private var pendingSelectionFallback: Task<String?, Never>?

    init(
        hotkey: HotkeyManager,
        recorder: AudioRecorder,
        groq: GroqClient,
        haiku: HaikuClient,
        context: ContextDetector,
        inserter: TextInserter,
        sound: SoundPlayer,
        history: HistoryStore?,
        snippets: SnippetStore,
        dictionary: DictionaryStore,
        config: HotkeyConfig,
        actionMenu: ActionMenuController
    ) {
        self.hotkey = hotkey
        self.recorder = recorder
        self.groq = groq
        self.haiku = haiku
        self.context = context
        self.inserter = inserter
        self.sound = sound
        self.history = history
        self.snippets = snippets
        self.dictionary = dictionary
        self.config = config
        self.actionMenu = actionMenu

        hotkey.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .pressed:
                    self.onHotkeyPressed()
                case .released:
                    self.onHotkeyReleased()
                }
            }
            .store(in: &cancellables)

        recorder.amplitudes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rms in
                guard let self else { return }
                self.amplitudeHistory.append(rms)
                if self.amplitudeHistory.count > self.amplitudeHistorySize {
                    self.amplitudeHistory.removeFirst(self.amplitudeHistory.count - self.amplitudeHistorySize)
                }
            }
            .store(in: &cancellables)

        // Live partial transcripts from on-device speech recognition. Each
        // partial replaces the previous (Apple's recognizer always returns
        // the full hypothesis-so-far, not deltas).
        speech.partialTranscripts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self else { return }
                self.liveTranscript = text
            }
            .store(in: &cancellables)

        // Audio buffers from the recorder go to both the WAV file (existing)
        // and the live recognizer (new). The consumer closure runs on the
        // audio thread; SpeechRecognizer.append hops to its own serial queue.
        recorder.bufferConsumer = { [speech] buffer in
            speech.append(buffer)
        }

        // Recorder publishes a max-length-hit signal; surface it in the HUD.
        recorder.maxLengthHits
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.flashError("Recording capped at 60s.")
            }
            .store(in: &cancellables)

        // Audio interruptions: cancel cleanly so we don't try to transcribe
        // a corrupt or empty file.
        let ws = NSWorkspace.shared.notificationCenter
        ws.publisher(for: NSWorkspace.willSleepNotification)
            .merge(with: ws.publisher(for: NSWorkspace.sessionDidResignActiveNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleAudioInterruption(reason: "system sleeping") }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleAudioInterruption(reason: "audio device changed") }
            .store(in: &cancellables)

        // Re-check Accessibility trust whenever the app comes to foreground,
        // which is the moment the user typically returns from System Settings
        // after granting permission. The banner clears within ~1s of them
        // flipping the toggle.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAccessibilityTrust() }
            .store(in: &cancellables)
    }

    /// Re-reads the current Accessibility trust state. Idempotent and safe
    /// to call from anywhere on main. TextInserter calls this when it sees
    /// `AXIsProcessTrusted() == false` at paste time — that's the latest
    /// possible signal we have that the grant was revoked.
    func refreshAccessibilityTrust() {
        let now = AccessibilityChecker.isTrusted
        if now != isAccessibilityTrusted {
            isAccessibilityTrusted = now
            FileLogger.shared.write(
                category: "AppState",
                level: "info",
                "Accessibility trust changed: \(now)"
            )
        }
    }

    /// Show the one-shot Accessibility-revoked alert if (a) we're not trusted
    /// and (b) we haven't already shown it this session. Callable from
    /// TextInserter when a paste is attempted in an untrusted state.
    func presentAccessibilityRevokedAlertIfNeeded() {
        // Always re-read first — caller's signal might be slightly stale.
        refreshAccessibilityTrust()
        guard !isAccessibilityTrusted else { return }
        guard !hasShownAccessibilityAlertThisSession else { return }
        hasShownAccessibilityAlertThisSession = true

        let alert = NSAlert()
        alert.messageText = "Whisperly needs Accessibility permission"
        alert.informativeText = """
            macOS reset Whisperly's Accessibility permission, so the dictation \
            you just spoke wasn't pasted.

            On the family-share (ad-hoc signed) build this happens after every \
            Sparkle update — the new binary has a different code-signing hash, \
            and macOS treats it as a fresh app. See SPARKLE.md.

            Click "Open Settings" to grant permission, then come back to \
            Whisperly. Your next dictation will paste normally.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")

        // Bring the app forward so the alert isn't buried.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            AccessibilityChecker.openSystemSettings()
        }
    }

    func bootstrap() {
        hotkey.start()
        if let history, config.historyEnabled {
            Task.detached { [history, retention = config.historyRetentionDays] in
                _ = try? await history.enforceRetention(retentionDays: retention)
            }
        }
        // Ask once at bootstrap so the user sees the dialog before their first
        // dictation rather than mid-recording. Result doesn't gate anything;
        // SpeechRecognizer.start() silently no-ops if not authorized.
        Task.detached {
            _ = await SpeechRecognizer.requestAuthorization()
        }
    }

    // MARK: - State machine

    private func onHotkeyPressed() {
        guard phase == .idle else {
            logger.info("Hotkey pressed while phase=\(String(describing: self.phase), privacy: .public) — ignoring re-entry.")
            FileLogger.shared.write(category: "AppState", level: "info", "Re-entry ignored — phase=\(self.phase)")
            return
        }

        // Read modifier state at press time — if Shift is held alongside the
        // hotkey, the user wants the action menu after transcription.
        // Action-menu mode bypasses AX selection: it always treats the
        // utterance as fresh dictation, never as an edit instruction.
        //
        // We don't only sample at press time — `installShiftMonitor()` keeps
        // watching during the press window so that adding Shift mid-recording
        // also routes to the menu. This makes the gesture forgiving: the user
        // can press Option first and decide to grab the menu a beat later.
        wantsActionMenu = NSEvent.modifierFlags.contains(.shift)
        installShiftMonitor()

        if wantsActionMenu {
            currentMode = .dictation
            modeDisplay = "Action menu"
            pendingSelectionFallback?.cancel()
            pendingSelectionFallback = nil
        } else if let selection = context.getSelectedText() {
            currentMode = .edit(selection: selection)
            modeDisplay = "Editing selection"
            pendingSelectionFallback = nil
            logger.info("Edit mode (AX) — selection: \(selection.count, privacy: .public) chars")
        } else {
            // AX returned nothing. Tentatively dictation; fire ⌘C fallback in
            // parallel. If it lands before the user releases, we upgrade to edit.
            currentMode = .dictation
            // Show translation target on the HUD when translation is enabled,
            // so the user has visual confirmation before they speak.
            if config.translationEnabled {
                modeDisplay = "→ \(config.translationOutputLanguage.nativeName)"
            } else {
                modeDisplay = nil
            }
            pendingSelectionFallback?.cancel()
            pendingSelectionFallback = Task { [context] in
                await context.getSelectedTextViaCopy()
            }
        }

        pressedAt = Date()
        amplitudeHistory.removeAll(keepingCapacity: true)
        liveTranscript = ""
        phase = .recording
        sound.playStart()
        FileLogger.shared.write(category: "AppState", level: "info", "Recording started")

        // Start live preview. Locale matches the user's chosen speaking
        // language when translation is on; defaults to system locale otherwise.
        let speechLocale: String? = config.translationEnabled
            ? config.translationInputLanguage.whisperCode
            : nil
        speech.start(localeCode: speechLocale)

        Task { [recorder] in
            do {
                try await recorder.startRecording()
            } catch {
                await MainActor.run {
                    self.flashError(error.localizedDescription)
                }
            }
        }
    }

    private func onHotkeyReleased() {
        let pressedAt = self.pressedAt
        self.pressedAt = nil

        guard phase == .recording else { return }

        let held = pressedAt.map { Date().timeIntervalSince($0) } ?? 0

        if held < minimumHoldDuration {
            logger.info("Hold duration \(String(format: "%.3f", held))s under threshold — cancelling.")
            recorder.cancel()
            speech.stop()
            pendingSelectionFallback?.cancel()
            pendingSelectionFallback = nil
            tearDownShiftMonitor()
            phase = .idle
            modeDisplay = nil
            liveTranscript = ""
            return
        }

        // Stop watching for Shift now that the user's released the hotkey —
        // any further Shift presses are unrelated.
        tearDownShiftMonitor()

        inFlightTask?.cancel()
        inFlightTask = Task { [weak self] in
            await self?.runPipeline(holdDuration: held)
        }
    }

    private func runPipeline(holdDuration: TimeInterval) async {
        // Stop the live recognizer immediately on release. Whisper takes over
        // for the canonical transcription; the partial preview is no longer
        // useful past this point.
        speech.stop()

        let appName = context.frontmostAppName()

        // Resolve the Cmd+C fallback, if any, before deciding the cycle mode.
        // We only "upgrade" dictation→edit if the fallback returned a selection
        // and we're still in dictation mode (user didn't already get an AX hit).
        if let pending = pendingSelectionFallback {
            let fallback = await pending.value
            pendingSelectionFallback = nil
            if let fallback, case .dictation = currentMode {
                currentMode = .edit(selection: fallback)
                modeDisplay = "Editing selection"
                logger.info("Edit mode (⌘C fallback) — selection: \(fallback.count, privacy: .public) chars")
                FileLogger.shared.write(category: "AppState", level: "info", "Edit mode via Cmd+C fallback")
            }
        }
        let cycleMode = currentMode

        // 1. Stop recording → URL
        phase = .transcribing
        sound.playStop()
        let audioURL: URL
        do {
            audioURL = try await recorder.stopRecording()
        } catch AudioRecorderError.noSpeechDetected {
            flashError("No speech detected.")
            return
        } catch {
            flashError(error.localizedDescription)
            return
        }

        // 2. Transcribe — Groq first; fall back to on-device if Groq's
        //    unreachable. Auth/bad-input errors don't fall back since local
        //    won't fix those.
        let biasingTerms = dictionary.topTermsForBiasing(limit: 20)
        // When translation is on, use the user's chosen speaking language
        // (whisperCode is nil for .auto, which omits the field). When off,
        // keep the original "en" default so existing users see no change.
        let languageCode: String? = config.translationEnabled
            ? config.translationInputLanguage.whisperCode
            : "en"
        let transcript: String
        var usedOfflineFallback = false
        do {
            transcript = try await groq.transcribe(audioURL: audioURL, biasingTerms: biasingTerms, languageCode: languageCode)
        } catch {
            if shouldFallBackToLocal(error: error), local.isAuthorized {
                logger.warning("Groq failed (\(error.localizedDescription, privacy: .public)) — trying on-device transcription.")
                FileLogger.shared.write(category: "AppState", level: "warn", "Groq failed; trying local fallback: \(error.localizedDescription)")
                modeDisplay = "Offline mode"
                do {
                    transcript = try await local.transcribeFile(at: audioURL, languageCode: languageCode)
                    usedOfflineFallback = true
                } catch {
                    try? FileManager.default.removeItem(at: audioURL)
                    FileLogger.shared.write(category: "AppState", level: "error", "Local fallback failed: \(error.localizedDescription)")
                    flashError("Offline mode failed: \(error.localizedDescription)")
                    return
                }
            } else {
                try? FileManager.default.removeItem(at: audioURL)
                FileLogger.shared.write(category: "AppState", level: "error", "Groq failed (no fallback): \(error.localizedDescription)")
                flashError(error.localizedDescription)
                return
            }
        }
        try? FileManager.default.removeItem(at: audioURL)

        guard !transcript.isEmpty else {
            logger.info("Empty transcript — nothing to paste.")
            phase = .idle
            modeDisplay = nil
            return
        }

        let dictionaryJSON = dictionary.jsonForPrompt()

        // Action-menu mode: user dictated with Right Option + Shift. Show the
        // 4-button menu above the HUD, suspend until they pick (or Esc),
        // then run Haiku.transform with the chosen style.
        if wantsActionMenu, !usedOfflineFallback {
            FileLogger.shared.write(category: "AppState", level: "info", "Action menu shown")
            let chosen = await actionMenu.choose()
            guard let style = chosen else {
                logger.info("Action menu cancelled — no paste.")
                phase = .idle
                modeDisplay = nil
                wantsActionMenu = false
                return
            }
            wantsActionMenu = false
            phase = .cleaning
            modeDisplay = style.label
            let cleaned: String
            do {
                cleaned = try await haikuWithRetry { [haiku] in
                    try await haiku.transform(transcript: transcript, style: style, appName: appName, dictionaryJSON: dictionaryJSON)
                }
            } catch {
                logger.error("Haiku transform (\(style.rawValue, privacy: .public)) failed; falling back to raw. Error: \(error.localizedDescription, privacy: .public)")
                FileLogger.shared.write(category: "AppState", level: "error", "Haiku transform failed: \(error.localizedDescription)")
                phase = .pasting
                await inserter.paste(transcript)
                flashWarning("\(style.label) failed — \(error.localizedDescription)")
                return
            }
            phase = .pasting
            await inserter.paste(cleaned)
            phase = .idle
            modeDisplay = nil
            await logHistory(
                mode: .command,
                appName: appName,
                rawTranscript: transcript,
                cleanedText: cleaned,
                selectionInput: nil,
                holdDuration: holdDuration
            )
            return
        }

        // Offline path: Groq fell over and we used the local transcriber.
        // Snippets still work (they're pure text matching). Edit mode can't
        // run because we have no way to rewrite the selection without Haiku.
        // Everything else gets the raw local transcript pasted with a brief
        // "not polished" warning, so the user gets *something* useful instead
        // of a frozen "transcribing…" state.
        if usedOfflineFallback {
            // Snippet bypass — works offline, no LLM needed.
            if case .dictation = cycleMode,
               let snippet = SnippetMatcher.match(transcript: transcript, in: snippets.snippets) {
                logger.info("Offline + snippet matched: \(snippet.trigger, privacy: .public)")
                phase = .pasting
                await inserter.paste(snippet.expansion)
                phase = .idle
                modeDisplay = nil
                snippets.recordUse(id: snippet.id)
                await logHistory(
                    mode: .dictation,
                    appName: appName,
                    rawTranscript: transcript,
                    cleanedText: snippet.expansion,
                    selectionInput: nil,
                    holdDuration: holdDuration
                )
                return
            }

            // Edit mode requires Haiku to rewrite the selection. We can't
            // safely paste the spoken instruction over the user's selection,
            // so error out cleanly.
            if case .edit = cycleMode {
                flashError("Edit mode needs internet — try again when connected.")
                return
            }

            // Dictation / command / translation all paste raw locally.
            phase = .pasting
            await inserter.paste(transcript)
            phase = .idle
            modeDisplay = nil
            await logHistory(
                mode: .dictation,
                appName: appName,
                rawTranscript: transcript,
                cleanedText: transcript,
                selectionInput: nil,
                holdDuration: holdDuration
            )
            flashWarning("Offline mode — text not polished")
            return
        }

        // 3-translate: when translation is on (and we're not in edit mode),
        // skip snippet/command detection — both rely on English-language
        // matching that won't make sense on a non-English transcript.
        if case .dictation = cycleMode, config.translationEnabled {
            phase = .cleaning
            let cleaned: String
            do {
                let target = config.translationOutputLanguage
                cleaned = try await haikuWithRetry { [haiku] in
                    try await haiku.translate(transcript: transcript, targetLanguage: target, appName: appName, dictionaryJSON: dictionaryJSON)
                }
            } catch {
                logger.error("Haiku translate failed; pasting raw transcript. Error: \(error.localizedDescription, privacy: .public)")
                FileLogger.shared.write(category: "AppState", level: "error", "Haiku translate failed: \(error.localizedDescription)")
                phase = .pasting
                await inserter.paste(transcript)
                flashWarning("Translation skipped — \(error.localizedDescription)")
                return
            }
            phase = .pasting
            await inserter.paste(cleaned)
            phase = .idle
            modeDisplay = nil
            await logHistory(
                mode: .translation,
                appName: appName,
                rawTranscript: transcript,
                cleanedText: cleaned,
                selectionInput: nil,
                holdDuration: holdDuration
            )
            return
        }

        // 3a. Snippet bypass
        if case .dictation = cycleMode,
           let snippet = SnippetMatcher.match(transcript: transcript, in: snippets.snippets) {
            logger.info("Snippet matched: \(snippet.trigger, privacy: .public) → \(snippet.expansion.count, privacy: .public) chars")
            phase = .pasting
            await inserter.paste(snippet.expansion)
            phase = .idle
            modeDisplay = nil
            snippets.recordUse(id: snippet.id)
            await logHistory(
                mode: .dictation,
                appName: appName,
                rawTranscript: transcript,
                cleanedText: snippet.expansion,
                selectionInput: nil,
                holdDuration: holdDuration
            )
            return
        }

        // 3b. Haiku call (cleanup / edit / command).
        phase = .cleaning
        let cleaned: String
        let historyMode: HistoryEntry.Mode
        let selectionForLog: String?
        do {
            switch cycleMode {
            case .dictation:
                if CommandPrompt.looksLikeCommand(transcript) {
                    cleaned = try await haikuWithRetry { [haiku] in
                        try await haiku.command(transcript: transcript, appName: appName, dictionaryJSON: dictionaryJSON)
                    }
                    historyMode = .command
                    selectionForLog = nil
                } else {
                    let useGrammarFix = config.writingAssistance == .grammarFix
                    cleaned = try await haikuWithRetry { [haiku] in
                        try await haiku.cleanup(transcript: transcript, appName: appName, dictionaryJSON: dictionaryJSON, grammarFix: useGrammarFix)
                    }
                    historyMode = .dictation
                    selectionForLog = nil
                }
            case .edit(let selection):
                cleaned = try await haikuWithRetry { [haiku] in
                    try await haiku.editSelection(selection: selection, instruction: transcript, appName: appName, dictionaryJSON: dictionaryJSON)
                }
                historyMode = .edit
                selectionForLog = selection
            }
        } catch {
            // Haiku failed even after one retry. Paste the raw transcript (or
            // the unchanged selection in edit mode) so the user gets *something*,
            // and surface "polish skipped" so they know polish was bypassed.
            logger.error("Haiku failed; falling back. Error: \(error.localizedDescription, privacy: .public)")
            FileLogger.shared.write(category: "AppState", level: "error", "Haiku failed (after retry): \(error.localizedDescription)")
            phase = .pasting
            switch cycleMode {
            case .dictation:
                await inserter.paste(transcript)
            case .edit(let selection):
                await inserter.replaceSelection(with: selection)
            }
            flashWarning("Polish skipped — \(error.localizedDescription)")
            return
        }

        // 4. Paste
        phase = .pasting
        switch cycleMode {
        case .dictation:
            await inserter.paste(cleaned)
        case .edit:
            await inserter.replaceSelection(with: cleaned)
        }
        phase = .idle
        modeDisplay = nil

        // 5. History (off the hot path)
        await logHistory(
            mode: historyMode,
            appName: appName,
            rawTranscript: transcript,
            cleanedText: cleaned,
            selectionInput: selectionForLog,
            holdDuration: holdDuration
        )
    }

    // MARK: - Shift-during-press monitor

    /// Installs local + global flagsChanged monitors that flip
    /// `wantsActionMenu = true` if Shift becomes held mid-press. Idempotent —
    /// safe to call again before teardown. Also updates the HUD subtitle to
    /// "Action menu" so the user gets immediate visual confirmation that
    /// they've crossed the threshold.
    private func installShiftMonitor() {
        tearDownShiftMonitor()
        let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Global monitor closures don't run on @MainActor by default.
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event)
            }
        }
        shiftMonitorLocal = local
        shiftMonitorGlobal = global
    }

    private func tearDownShiftMonitor() {
        if let m = shiftMonitorLocal { NSEvent.removeMonitor(m); shiftMonitorLocal = nil }
        if let m = shiftMonitorGlobal { NSEvent.removeMonitor(m); shiftMonitorGlobal = nil }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard !wantsActionMenu else { return }  // already armed; nothing to do
        guard event.modifierFlags.contains(.shift) else { return }
        wantsActionMenu = true
        // Update the HUD subtitle live unless we're in edit mode (selection
        // overrides — user's existing selection takes precedence over a
        // mid-press Shift add).
        if case .dictation = currentMode {
            modeDisplay = "Action menu"
            FileLogger.shared.write(category: "AppState", level: "info", "Shift added mid-press; armed action menu")
        }
    }

    /// Decides whether a Groq failure warrants attempting on-device
    /// transcription. We skip the fallback for errors that local recognition
    /// can't fix anyway (auth, corrupt audio).
    private func shouldFallBackToLocal(error: any Error) -> Bool {
        guard let groqError = error as? GroqClientError else {
            // Unknown error → try local as a last resort.
            return true
        }
        switch groqError {
        case .invalidAudioFile:
            // The recording itself is broken — local won't help.
            return false
        case .unauthorized, .missingAPIKey, .rateLimited, .server, .network, .decoding:
            // Network / server / quota / config issues → local can recover.
            // (We even fall back on missingAPIKey so the app isn't dead in
            // the water if the user clears their key while offline.)
            return true
        }
    }

    /// Wraps a Haiku call with one retry on rate-limit. After 1 second we try
    /// again; a second failure throws so the caller can fall back.
    private func haikuWithRetry(_ call: @escaping () async throws -> String) async throws -> String {
        do {
            return try await call()
        } catch HaikuClientError.rateLimited {
            logger.warning("Haiku rate-limited; retrying in 1s.")
            FileLogger.shared.write(category: "AppState", level: "warn", "Haiku rate-limited; retrying once")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return try await call()
        }
    }

    // MARK: - Audio interruption

    private func handleAudioInterruption(reason: String) {
        guard phase == .recording else { return }
        logger.warning("Audio interruption: \(reason, privacy: .public) — cancelling.")
        FileLogger.shared.write(category: "AppState", level: "warn", "Audio interrupted: \(reason)")
        recorder.cancel()
        speech.stop()
        pendingSelectionFallback?.cancel()
        pendingSelectionFallback = nil
        tearDownShiftMonitor()
        liveTranscript = ""
        flashError("Recording interrupted (\(reason)).")
    }

    // MARK: - History

    private func logHistory(
        mode: HistoryEntry.Mode,
        appName: String,
        rawTranscript: String,
        cleanedText: String,
        selectionInput: String?,
        holdDuration: TimeInterval
    ) async {
        guard let history, config.historyEnabled else { return }
        let entry = HistoryEntry(
            mode: mode,
            targetApp: appName,
            rawTranscript: rawTranscript,
            cleanedText: cleanedText,
            selectionInput: selectionInput,
            audioDurationSeconds: holdDuration,
            wordCount: cleanedText.split { $0.isWhitespace || $0.isNewline }.count
        )
        Task.detached { [history] in
            _ = try? await history.insert(entry)
        }
    }

    // MARK: - HUD messaging

    private func flashError(_ message: String) {
        logger.error("\(message, privacy: .public)")
        phase = .error(message)
        modeDisplay = nil
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                guard let self else { return }
                if case .error = self.phase {
                    self.phase = .idle
                }
            }
        }
    }

    /// Like flashError, but used when we've already pasted something and just
    /// want to surface a warning that polish was skipped. Goes back to .idle
    /// after the message.
    private func flashWarning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        phase = .error(message)
        modeDisplay = nil
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                guard let self else { return }
                if case .error = self.phase {
                    self.phase = .idle
                }
            }
        }
    }
}
