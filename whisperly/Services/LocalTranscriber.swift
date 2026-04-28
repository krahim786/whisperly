import Foundation
import Speech
import os

enum LocalTranscriberError: LocalizedError {
    case authorizationDenied
    case localeUnavailable(String)
    case noSpeechDetected
    case recognizerFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Speech Recognition permission is not granted. Enable it in System Settings → Privacy & Security → Speech Recognition."
        case .localeUnavailable(let id):
            return "On-device speech recognition isn't available for \(id). Install the language pack via System Settings → Keyboard → Dictation."
        case .noSpeechDetected:
            return "No speech detected in the recording."
        case .recognizerFailed(let msg):
            return "Local recognition failed: \(msg)"
        }
    }
}

/// Transcribes a finished WAV file with Apple's `SFSpeechRecognizer`, fully
/// on-device (no network). Used by AppState as a fallback when Groq is
/// unreachable. The same service that powers the live preview during
/// recording is *separate* (`SpeechRecognizer`) — that one streams audio
/// buffers; this one consumes a finished file.
///
/// Limitations vs Whisper:
/// - Less accurate, especially for technical vocabulary
/// - Lossy on punctuation
/// - Locale must be installed on-device (System Settings → Keyboard →
///   Dictation → "Edit Languages")
nonisolated final class LocalTranscriber: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.karim.whisperly", category: "LocalTranscriber")

    /// Whether the user has granted Speech Recognition permission. AppState
    /// checks this before deciding to attempt the fallback.
    var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// Transcribe a finished audio file on-device.
    ///
    /// `languageCode` is an ISO 639-1 hint (e.g. "en", "es"). nil falls back
    /// to the system locale — appropriate when the user has translation off
    /// or has set "Auto-detect" as the speaking language.
    func transcribeFile(at url: URL, languageCode: String?) async throws -> String {
        guard isAuthorized else {
            throw LocalTranscriberError.authorizationDenied
        }

        let locale: Locale = languageCode.flatMap { code in
            code.isEmpty ? nil : Locale(identifier: code)
        } ?? Locale.current

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw LocalTranscriberError.localeUnavailable(locale.identifier)
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true

        let start = Date()
        let transcript: String = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            // SFSpeechRecognizer's callback can fire multiple times (partial
            // results, final, then error). Latch resumed=true so we resume
            // the continuation exactly once.
            let box = ResumeBox()
            recognizer.recognitionTask(with: request) { result, error in
                if box.resumed { return }
                if let error {
                    box.resumed = true
                    cont.resume(throwing: LocalTranscriberError.recognizerFailed(error.localizedDescription))
                    return
                }
                guard let result, result.isFinal else { return }
                box.resumed = true
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    cont.resume(throwing: LocalTranscriberError.noSpeechDetected)
                } else {
                    cont.resume(returning: text)
                }
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        logger.info("Local transcribe (locale: \(locale.identifier, privacy: .public)) → \(String(format: "%.2f", elapsed))s, \(transcript.count, privacy: .public) chars")
        return transcript
    }

    /// Per-task latch for the once-resume pattern. Apple's APIs callback on
    /// internal queues, so we keep this on the heap and rely on the box not
    /// being shared across multiple recognitions.
    private final class ResumeBox: @unchecked Sendable {
        var resumed: Bool = false
    }
}
