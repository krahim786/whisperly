import Combine
import Foundation
import os
import SwiftUI

/// Single ObservableObject that owns the dictation state machine and the
/// references to all collaborators. The HotkeyManager calls
/// `onHotkeyPressed`/`onHotkeyReleased`; this class drives the rest.
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

    private var currentMode: DictationMode = .dictation

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
            return
        }

        let selection = context.getSelectedText()
        if let selection {
            currentMode = .edit(selection: selection)
            modeDisplay = "Editing selection"
            logger.info("Edit mode — selection: \(selection.count, privacy: .public) chars")
        } else {
            currentMode = .dictation
            modeDisplay = nil
        }

        pressedAt = Date()
        amplitudeHistory.removeAll(keepingCapacity: true)
        phase = .recording
        sound.playStart()
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

        // 2. Groq transcribe (with dictionary biasing terms)
        let biasingTerms = dictionary.topTermsForBiasing(limit: 20)
        let transcript: String
        do {
            transcript = try await groq.transcribe(audioURL: audioURL, biasingTerms: biasingTerms)
        } catch {
            try? FileManager.default.removeItem(at: audioURL)
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

        // 3. Resolve mode and produce final text.
        //    Edit mode is locked in at press time and bypasses snippet/command checks.
        //    Otherwise: snippet expansion (no LLM) → command mode → dictation cleanup.
        let dictionaryJSON = dictionary.jsonForPrompt()

        // 3a. Snippet bypass (only when not editing a selection).
        if case .dictation = cycleMode,
           let snippet = SnippetMatcher.match(transcript: transcript, in: snippets.snippets) {
            logger.info("Snippet matched: \(snippet.trigger, privacy: .public) → expansion (\(snippet.expansion.count, privacy: .public) chars)")
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
                    cleaned = try await haiku.command(transcript: transcript, appName: appName, dictionaryJSON: dictionaryJSON)
                    historyMode = .command
                    selectionForLog = nil
                } else {
                    cleaned = try await haiku.cleanup(transcript: transcript, appName: appName, dictionaryJSON: dictionaryJSON)
                    historyMode = .dictation
                    selectionForLog = nil
                }
            case .edit(let selection):
                cleaned = try await haiku.editSelection(selection: selection, instruction: transcript, appName: appName, dictionaryJSON: dictionaryJSON)
                historyMode = .edit
                selectionForLog = selection
            }
        } catch {
            logger.error("Haiku failed; falling back. Error: \(error.localizedDescription, privacy: .public)")
            phase = .pasting
            switch cycleMode {
            case .dictation:
                await inserter.paste(transcript)
            case .edit(let selection):
                await inserter.replaceSelection(with: selection)
            }
            phase = .idle
            modeDisplay = nil
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
}
