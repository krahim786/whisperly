import AVFoundation
import Combine
import Foundation
import os

enum AudioRecorderError: LocalizedError {
    case permissionDenied
    case engineFailure(any Error)
    case noActiveRecording
    case converterUnavailable
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone permission was denied. Enable it in System Settings → Privacy & Security → Microphone."
        case .engineFailure(let error): return "Audio engine error: \(error.localizedDescription)"
        case .noActiveRecording: return "No recording in progress."
        case .converterUnavailable: return "Couldn't create audio converter."
        case .noSpeechDetected: return "No speech detected."
        }
    }
}

/// Records mic audio to a 16 kHz mono 16-bit PCM WAV file in the temp directory.
///
/// Day 2 additions:
/// - Per-buffer RMS amplitude is published on `amplitudes` for HUD visualization.
/// - Voice-activity detection (VAD) trims leading silence: buffers are buffered
///   in a small ring until the first above-threshold buffer arrives, at which
///   point the ring is flushed to disk and subsequent buffers stream straight
///   through. This preserves a small window of pre-speech audio so the speech
///   onset isn't clipped.
/// - A safety timer auto-stops the engine after `maxRecordingSeconds`. The
///   caller can still invoke `stopRecording()` to read the URL; if the engine
///   already self-stopped, the URL is still valid.
final class AudioRecorder: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.karim.whisperly", category: "AudioRecorder")

    private let engine = AVAudioEngine()

    private let queue = DispatchQueue(label: "com.karim.whisperly.audio")
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var processingFormat: AVAudioFormat?
    private var currentURL: URL?
    private var isRecording = false

    // VAD state.
    private let vadThresholdRMS: Float = 0.012      // ~ -38 dBFS
    private let vadRingCapacity = 8                 // ~80–160 ms of pre-roll depending on buffer size
    private let vadTrailingSilenceSeconds: TimeInterval = 2.5
    private var vadHasFlushed = false
    private var vadRing: [AVAudioPCMBuffer] = []
    private var receivedAnySpeech = false
    private var lastSpeechAt: Date?

    // Max recording length safeguard. Engine auto-stops; the consumer can still
    // call stopRecording() afterward to read the URL.
    private let maxRecordingSeconds: TimeInterval = 60

    // Amplitude publishing — RMS values 0...1.
    nonisolated private let amplitudeSubject = PassthroughSubject<Float, Never>()
    /// RMS amplitude (0...1) per audio buffer. Subscribers should hop to main
    /// before assigning to UI state.
    nonisolated var amplitudes: AnyPublisher<Float, Never> {
        amplitudeSubject.eraseToAnyPublisher()
    }

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

        // Schedule the max-length safeguard outside the synchronous block.
        scheduleMaxLengthGuard()
    }

    func stopRecording() async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, any Error>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: AudioRecorderError.noActiveRecording)
                    return
                }
                guard let url = self.currentURL else {
                    cont.resume(throwing: AudioRecorderError.noActiveRecording)
                    return
                }
                let hadSpeech = self.receivedAnySpeech
                self.endRecordingOnQueue()
                if !hadSpeech {
                    cont.resume(throwing: AudioRecorderError.noSpeechDetected)
                } else {
                    cont.resume(returning: url)
                }
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

        guard let proc = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else {
            throw AudioRecorderError.converterUnavailable
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: proc) else {
            throw AudioRecorderError.converterUnavailable
        }
        self.processingFormat = proc
        self.converter = conv
        self.vadHasFlushed = false
        self.vadRing.removeAll(keepingCapacity: true)
        self.receivedAnySpeech = false
        self.lastSpeechAt = nil

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

        let captureConverter = conv
        let captureProc = proc
        let captureLogger = logger
        let captureQueue = queue
        let captureSubject = amplitudeSubject

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { buffer, _ in
            // Audio thread: convert → emit RMS → hand off to serial queue.
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

            // RMS over the converted (16 kHz mono Float32) buffer.
            let rms = Self.rms(of: outBuffer)
            captureSubject.send(rms)

            captureQueue.async { [weak self] in
                guard let self else { return }
                self.handleConvertedBuffer(outBuffer, rms: rms)
            }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
        logger.info("Recording started → \(url.lastPathComponent, privacy: .public) (input: \(inputFormat.sampleRate, privacy: .public) Hz, \(inputFormat.channelCount, privacy: .public) ch)")
    }

    /// Runs on `queue`. Decides whether to write the buffer to disk or hold
    /// it in the leading-silence ring.
    private func handleConvertedBuffer(_ buffer: AVAudioPCMBuffer, rms: Float) {
        guard let file = audioFile else { return }

        let isSpeech = rms >= vadThresholdRMS

        if vadHasFlushed {
            // Past the leading silence gate. Apply trailing silence trim:
            // if we've gone vadTrailingSilenceSeconds without any speech buffer,
            // stop writing further buffers (the engine keeps running for amplitude
            // updates, but the file stays at its current length).
            if isSpeech {
                lastSpeechAt = Date()
                receivedAnySpeech = true
                do { try file.write(from: buffer) }
                catch { logger.error("AVAudioFile write failed: \(error.localizedDescription, privacy: .public)") }
            } else if let last = lastSpeechAt, Date().timeIntervalSince(last) <= vadTrailingSilenceSeconds {
                // Recent enough to still be a within-utterance pause — keep the silence
                // so cadence isn't lost.
                do { try file.write(from: buffer) }
                catch { logger.error("AVAudioFile write failed: \(error.localizedDescription, privacy: .public)") }
            } else {
                // Trailing-silence territory; drop the buffer.
            }
            return
        }

        if isSpeech {
            // First above-threshold buffer. Flush the ring + write current.
            vadHasFlushed = true
            receivedAnySpeech = true
            lastSpeechAt = Date()
            for ringBuffer in vadRing {
                try? file.write(from: ringBuffer)
            }
            vadRing.removeAll(keepingCapacity: true)
            do {
                try file.write(from: buffer)
            } catch {
                logger.error("AVAudioFile write failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            // Hold in ring; drop oldest if at capacity.
            vadRing.append(buffer)
            if vadRing.count > vadRingCapacity {
                vadRing.removeFirst(vadRing.count - vadRingCapacity)
            }
        }
    }

    private func endRecordingOnQueue() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioFile = nil
        converter = nil
        processingFormat = nil
        vadRing.removeAll(keepingCapacity: false)
        vadHasFlushed = false
        lastSpeechAt = nil
        isRecording = false
        if let url = currentURL {
            logger.info("Recording stopped → \(url.lastPathComponent, privacy: .public) (speech detected: \(self.receivedAnySpeech, privacy: .public))")
        }
    }

    private func scheduleMaxLengthGuard() {
        let limit = maxRecordingSeconds
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.isRecording else { return }
                self.logger.warning("Max recording duration (\(limit, privacy: .public)s) hit — auto-stopping engine; URL remains valid.")
                if self.engine.isRunning {
                    self.engine.inputNode.removeTap(onBus: 0)
                    self.engine.stop()
                }
                // Leave file/converter set so a subsequent stopRecording() can
                // still read the URL. We just released the hardware.
            }
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

    // MARK: - DSP

    /// Mean-square root over the first channel of a Float32 PCM buffer.
    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<frameLength {
            let v = samples[i]
            sum += v * v
        }
        return (sum / Float(frameLength)).squareRoot()
    }
}
