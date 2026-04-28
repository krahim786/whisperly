@preconcurrency import AVFoundation
import Combine
import Foundation
import Speech
import os

/// Wraps `SFSpeechRecognizer` to give the HUD a live partial transcript as
/// the user speaks. The Groq Whisper round-trip is still authoritative — this
/// is *only* for visual feedback during recording. If the user denies
/// permission, or the chosen locale isn't supported on-device, the rest of
/// the app keeps working unchanged; the HUD just doesn't show a preview.
///
/// Concurrency: SFSpeechRecognizer's callbacks fire on internal queues. We
/// hop everything that touches @Published state to the main actor explicitly.
nonisolated final class SpeechRecognizer: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.karim.whisperly", category: "SpeechRecognizer")

    nonisolated let partialTranscripts = PassthroughSubject<String, Never>()

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isRunning: Bool = false
    private let queue = DispatchQueue(label: "com.karim.whisperly.speech")

    init() {}

    /// True when a stream is actively transcribing.
    var streaming: Bool {
        var v = false
        queue.sync { v = self.isRunning }
        return v
    }

    /// Request authorization. Result is delivered async; safe to call any
    /// number of times. Returns the current state.
    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    /// Start a new live-transcription stream for `localeCode` (e.g. "en", "es").
    /// Pass nil to use the system's current locale. Returns false if the
    /// recognizer can't be set up — caller should silently degrade and skip
    /// the live preview.
    @discardableResult
    func start(localeCode: String?) -> Bool {
        var ok = false
        queue.sync {
            self.stopOnQueue()

            // Authorization must already be granted; we don't block here.
            guard Self.authorizationStatus == .authorized else {
                self.logger.debug("SpeechRecognizer: authorization not granted (\(Self.authorizationStatus.rawValue, privacy: .public)) — skipping live preview")
                return
            }

            let locale: Locale
            if let code = localeCode, !code.isEmpty {
                locale = Locale(identifier: code)
            } else {
                locale = Locale.current
            }

            guard let r = SFSpeechRecognizer(locale: locale), r.isAvailable else {
                self.logger.debug("SpeechRecognizer: unavailable for locale \(locale.identifier, privacy: .public) — skipping live preview")
                return
            }

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = true  // free + private; falls back to server-side if false

            let task = r.recognitionTask(with: req) { [weak self] result, error in
                guard let self else { return }
                if let error {
                    // Cancellation throws as an error too — only log unexpected ones.
                    let nsErr = error as NSError
                    if nsErr.domain == "kAFAssistantErrorDomain" && nsErr.code == 203 {
                        // 203 = "Retry" / no speech detected. Benign.
                    } else {
                        self.logger.debug("SFSpeechRecognitionTask error: \(error.localizedDescription, privacy: .public)")
                    }
                    return
                }
                guard let result else { return }
                self.partialTranscripts.send(result.bestTranscription.formattedString)
            }

            self.recognizer = r
            self.request = req
            self.task = task
            self.isRunning = true
            ok = true
            self.logger.info("SpeechRecognizer started for locale \(locale.identifier, privacy: .public)")
        }
        return ok
    }

    /// Feed a converted PCM buffer (16 kHz mono Float32 from AudioRecorder's
    /// converter) into the active recognition request. Safe to call from any
    /// thread.
    ///
    /// The buffer is `nonisolated(unsafe)` because `AVAudioPCMBuffer` isn't
    /// Sendable in Swift 6. In practice it's safe — the audio engine hands
    /// us a fresh buffer each tap and we only read from it serially.
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        let unsafeBuffer = UnsafeAudioBuffer(buffer)
        queue.async {
            guard self.isRunning, let request = self.request else { return }
            request.append(unsafeBuffer.value)
        }
    }

    /// Sendable wrapper around AVAudioPCMBuffer for crossing the queue hop.
    /// AVFoundation hands us a buffer per tap that no other code touches; the
    /// recognizer queue is the sole consumer.
    private struct UnsafeAudioBuffer: @unchecked Sendable {
        let value: AVAudioPCMBuffer
        init(_ buffer: AVAudioPCMBuffer) { self.value = buffer }
    }

    func stop() {
        queue.async {
            self.stopOnQueue()
        }
    }

    private func stopOnQueue() {
        guard isRunning else { return }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        recognizer = nil
        isRunning = false
        logger.info("SpeechRecognizer stopped")
    }
}
