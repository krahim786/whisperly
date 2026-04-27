import AVFoundation
import Foundation
import os

enum AudioRecorderError: LocalizedError {
    case permissionDenied
    case engineFailure(any Error)
    case noActiveRecording
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone permission was denied. Enable it in System Settings → Privacy & Security → Microphone."
        case .engineFailure(let error): return "Audio engine error: \(error.localizedDescription)"
        case .noActiveRecording: return "No recording in progress."
        case .converterUnavailable: return "Couldn't create audio converter."
        }
    }
}

/// Records mic audio to a 16 kHz mono 16-bit PCM WAV file in the temp directory.
///
/// Concurrency: the AVAudioEngine tap callback runs on a non-main, real-time-ish
/// audio queue. We isolate all mutable state (audio file, converter) to a serial
/// dispatch queue so it can be safely touched from both the start/stop methods
/// and the tap callback.
final class AudioRecorder: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.karim.whisperly", category: "AudioRecorder")

    // Audio engine is owned by this class. The input node tap is installed once
    // per recording cycle and removed on stop.
    private let engine = AVAudioEngine()

    // Serial queue protects mutable state below.
    private let queue = DispatchQueue(label: "com.karim.whisperly.audio")
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var processingFormat: AVAudioFormat?
    private var currentURL: URL?
    private var isRecording = false

    init() {
        cleanupOldTempFiles()
    }

    // MARK: - Permission

    func requestMicPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    // MARK: - Recording

    func startRecording() async throws {
        let permitted = await requestMicPermission()
        guard permitted else { throw AudioRecorderError.permissionDenied }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: AudioRecorderError.noActiveRecording)
                    return
                }
                if self.isRecording {
                    self.logger.warning("startRecording called while already recording — ignoring.")
                    cont.resume(returning: ())
                    return
                }
                do {
                    try self.beginRecordingOnQueue()
                    cont.resume(returning: ())
                } catch {
                    cont.resume(throwing: AudioRecorderError.engineFailure(error))
                }
            }
        }
    }

    func stopRecording() async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, any Error>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: AudioRecorderError.noActiveRecording)
                    return
                }
                guard self.isRecording, let url = self.currentURL else {
                    cont.resume(throwing: AudioRecorderError.noActiveRecording)
                    return
                }
                self.endRecordingOnQueue()
                cont.resume(returning: url)
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.endRecordingOnQueue()
            if let url = self.currentURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Internals (must run on `queue`)

    private func beginRecordingOnQueue() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "Whisperly.AudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Input format has zero sample rate (no mic?)"])
        }

        // 16 kHz mono Float32 — Whisper's preferred input. We let AVAudioFile
        // serialize to 16-bit PCM WAV via its `settings`.
        guard let proc = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else {
            throw AudioRecorderError.converterUnavailable
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: proc) else {
            throw AudioRecorderError.converterUnavailable
        }
        self.processingFormat = proc
        self.converter = conv

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("whisperly-\(UUID().uuidString).wav")
        let fileSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.audioFile = file
        self.currentURL = url

        // Capture references for the tap closure — avoids capturing self.
        let captureConverter = conv
        let captureProc = proc
        let captureLogger = logger
        let captureQueue = queue

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { buffer, _ in
            // This closure runs on AVAudioEngine's audio thread.
            // Convert to 16 kHz mono Float32, then hop to our serial queue
            // for the file write so writes don't race with stop().
            let outputFrameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * captureProc.sampleRate / buffer.format.sampleRate
            ) + 1024
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: captureProc, frameCapacity: outputFrameCount) else {
                return
            }

            var bufferConsumed = false
            var error: NSError?
            let status = captureConverter.convert(to: outBuffer, error: &error) { _, outStatus in
                if bufferConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                bufferConsumed = true
                return buffer
            }

            if let error {
                captureLogger.error("Audio conversion error: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard status != .error, outBuffer.frameLength > 0 else { return }

            captureQueue.async { [weak self] in
                guard let self, let file = self.audioFile else { return }
                do {
                    try file.write(from: outBuffer)
                } catch {
                    self.logger.error("AVAudioFile write failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
        logger.info("Recording started → \(url.lastPathComponent, privacy: .public) (input: \(inputFormat.sampleRate, privacy: .public) Hz, \(inputFormat.channelCount, privacy: .public) ch)")
    }

    private func endRecordingOnQueue() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        // Drop our reference so the file is finalized/closed before we hand the URL back.
        audioFile = nil
        converter = nil
        processingFormat = nil
        isRecording = false
        if let url = currentURL {
            logger.info("Recording stopped → \(url.lastPathComponent, privacy: .public)")
        }
    }

    // MARK: - Cleanup

    private func cleanupOldTempFiles() {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let oneHourAgo = Date().addingTimeInterval(-3_600)
        for item in items where item.lastPathComponent.hasPrefix("whisperly-") && item.pathExtension == "wav" {
            let mod = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if mod < oneHourAgo {
                try? fm.removeItem(at: item)
            }
        }
    }
}
