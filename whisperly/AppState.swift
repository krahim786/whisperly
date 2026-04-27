import Combine
import Foundation
import os
import SwiftUI

/// Single ObservableObject that owns the dictation state machine and the
/// references to all the Day 1 collaborators. The HotkeyManager calls
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

    /// Brief tap (< 200ms) is treated as accidental — we abandon the cycle.
    private let minimumHoldDuration: TimeInterval = 0.2

    private let logger = Logger(subsystem: "com.karim.whisperly", category: "AppState")

    private let hotkey: HotkeyManager
    private let recorder: AudioRecorder
    private let groq: GroqClient
    private let haiku: HaikuClient
    private let context: ContextDetector
    private let inserter: TextInserter

    private var cancellables = Set<AnyCancellable>()
    private var pressedAt: Date?
    private var inFlightTask: Task<Void, Never>?

    init(
        hotkey: HotkeyManager,
        recorder: AudioRecorder,
        groq: GroqClient,
        haiku: HaikuClient,
        context: ContextDetector,
        inserter: TextInserter
    ) {
        self.hotkey = hotkey
        self.recorder = recorder
        self.groq = groq
        self.haiku = haiku
        self.context = context
        self.inserter = inserter

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
        phase = .recording
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
        let audioURL: URL
        do {
            audioURL = try await recorder.stopRecording()
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
            // Day 1 fallback policy: if Haiku fails, paste the raw transcript so
            // the user still gets *something*. Day 6 will refine this.
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
