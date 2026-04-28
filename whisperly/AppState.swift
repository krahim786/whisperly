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

    private var cancellables = Set<AnyCancellable>()
    private var pressedAt: Date?
    private var inFlightTask: Task<Void, Never>?

    /// Mode for the cycle currently in flight. Set on press, consumed on pipeline completion.
    private var currentMode: DictationMode = .dictation

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
        config: HotkeyConfig
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
    }

    func bootstrap() {
        hotkey.start()
        if let history, config.historyEnabled {
            Task.detached { [history, retention = config.historyRetentionDays] in
                _ = try? await history.enforceRetention(retentionDays: retention)
            }
        }
    }

    // MARK: - State machine

    private func onHotkeyPressed() {
        guard phase == .idle else {
            logger.info("Hotkey pressed while phase=\(String(describing: self.phase), privacy: .public) — ignoring re-entry.")
            FileLogger.shared.write(category: "AppState", level: "info", "Re-entry ignored — phase=\(self.phase)")
            return
        }

        // Synchronous AX read first — fast path. Most native apps return here.
        if let selection = context.getSelectedText() {
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
        phase = .recording
        sound.playStart()
        FileLogger.shared.write(category: "AppState", level: "info", "Recording started")
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
            pendingSelectionFallback?.cancel()
            pendingSelectionFallback = nil
            phase = .idle
            modeDisplay = nil
            return
        }

        inFlightTask?.cancel()
        inFlightTask = Task { [weak self] in
            await self?.runPipeline(holdDuration: held)
        }
    }

    private func runPipeline(holdDuration: TimeInterval) async {
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

        // 2. Groq transcribe
        let biasingTerms = dictionary.topTermsForBiasing(limit: 20)
        // When translation is on, use the user's chosen speaking language
        // (whisperCode is nil for .auto, which omits the field). When off,
        // keep the original "en" default so existing users see no change.
        let languageCode: String? = config.translationEnabled
            ? config.translationInputLanguage.whisperCode
            : "en"
        let transcript: String
        do {
            transcript = try await groq.transcribe(audioURL: audioURL, biasingTerms: biasingTerms, languageCode: languageCode)
        } catch {
            try? FileManager.default.removeItem(at: audioURL)
            FileLogger.shared.write(category: "AppState", level: "error", "Groq failed: \(error.localizedDescription)")
            flashError(error.localizedDescription)
            return
        }
        try? FileManager.default.removeItem(at: audioURL)

        guard !transcript.isEmpty else {
            logger.info("Empty transcript — nothing to paste.")
            phase = .idle
            modeDisplay = nil
            return
        }

        let dictionaryJSON = dictionary.jsonForPrompt()

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
        pendingSelectionFallback?.cancel()
        pendingSelectionFallback = nil
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
