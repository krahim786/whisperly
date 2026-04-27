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

    @Published private(set) var phase: Phase = .idle

    /// Sliding window of the most recent RMS values published by the recorder.
    /// HUD reads this directly. Reset on entering `.recording`.
    @Published private(set) var amplitudeHistory: [Float] = []
    private let amplitudeHistorySize = 24

    /// Brief tap (< 200ms) is treated as accidental — we abandon the cycle.
    private let minimumHoldDuration: TimeInterval = 0.2

    private let logger = Logger(subsystem: "com.karim.whisperly", category: "AppState")

    private let hotkey: HotkeyManager
    private let recorder: AudioRecorder
    private let groq: GroqClient
    private let haiku: HaikuClient
    private let context: ContextDetector
    private let inserter: TextInserter
    private let sound: SoundPlayer

    private var cancellables = Set<AnyCancellable>()
    private var pressedAt: Date?
    private var inFlightTask: Task<Void, Never>?

    init(
        hotkey: HotkeyManager,
        recorder: AudioRecorder,
        groq: GroqClient,
        haiku: HaikuClient,
        context: ContextDetector,
        inserter: TextInserter,
        sound: SoundPlayer
    ) {
        self.hotkey = hotkey
        self.recorder = recorder
        self.groq = groq
        self.haiku = haiku
        self.context = context
        self.inserter = inserter
        self.sound = sound

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

        // Recorder amplitudes arrive on the audio thread; hop to main and
        // append to the sliding window.
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
    }

    // MARK: - State machine

    private func onHotkeyPressed() {
        guard phase == .idle else {
            logger.info("Hotkey pressed while phase=\(String(describing: self.phase), privacy: .public) — ignoring re-entry.")
            return
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

        guard phase == .recording else {
            // E.g. release fired during processing of a previous cycle — nothing to do.
            return
        }

        let held = pressedAt.map { Date().timeIntervalSince($0) } ?? 0

        if held < minimumHoldDuration {
            logger.info("Hold duration \(String(format: "%.3f", held))s under threshold — cancelling.")
            recorder.cancel()
            phase = .idle
            return
        }

        // Run the rest of the pipeline.
        inFlightTask?.cancel()
        inFlightTask = Task { [weak self] in
            await self?.runPipeline()
        }
    }

    private func runPipeline() async {
        let appName = context.frontmostAppName()

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
        let transcript: String
        do {
            transcript = try await groq.transcribe(audioURL: audioURL)
        } catch {
            try? FileManager.default.removeItem(at: audioURL)
            flashError(error.localizedDescription)
            return
        }

        // Best-effort cleanup of the temp wav.
        try? FileManager.default.removeItem(at: audioURL)

        guard !transcript.isEmpty else {
            logger.info("Empty transcript — nothing to paste.")
            phase = .idle
            return
        }

        // 3. Haiku cleanup
        phase = .cleaning
        let cleaned: String
        do {
            cleaned = try await haiku.cleanup(transcript: transcript, appName: appName)
        } catch {
            // Fallback: paste the raw transcript so the user still gets something.
            logger.error("Haiku cleanup failed; pasting raw transcript. Error: \(error.localizedDescription, privacy: .public)")
            phase = .pasting
            await inserter.paste(transcript)
            phase = .idle
            return
        }

        // 4. Paste
        phase = .pasting
        await inserter.paste(cleaned)
        phase = .idle
    }

    private func flashError(_ message: String) {
        logger.error("\(message, privacy: .public)")
        phase = .error(message)
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
