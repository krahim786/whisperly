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
    /// The OS reported the input bus in a half-baked state (zero sample rate
    /// or zero channels) when we tried to start recording. With Bluetooth this
    /// happens during the A2DP→HFP profile switch — the mic isn't actually
    /// available for ~100-500 ms after the user hits the hotkey. We bail
    /// cleanly here instead of letting the bad format reach `installTap`,
    /// which would raise an Obj-C exception and abort the process.
    case audioInputNotReady(sampleRate: Double, channelCount: AVAudioChannelCount)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone permission was denied. Enable it in System Settings → Privacy & Security → Microphone."
        case .engineFailure(let error): return "Audio engine error: \(error.localizedDescription)"
        case .noActiveRecording: return "No recording in progress."
        case .converterUnavailable: return "Couldn't create audio converter."
        case .noSpeechDetected: return "No speech detected."
        case .audioInputNotReady:
            return "Mic not ready — if you just connected Bluetooth, give it a second and try again."
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
    /// The format `converter` was created against. Used to detect mid-stream
    /// format changes — with Bluetooth the bus can renegotiate after the first
    /// few buffers, at which point we rebuild the converter rather than feeding
    /// the old one buffers it can't decode.
    private var converterInputFormat: AVAudioFormat?
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
    private var maxLengthTask: Task<Void, Never>?

    // Amplitude publishing — RMS values 0...1.
    nonisolated private let amplitudeSubject = PassthroughSubject<Float, Never>()
    /// RMS amplitude (0...1) per audio buffer. Subscribers should hop to main
    /// before assigning to UI state.
    nonisolated var amplitudes: AnyPublisher<Float, Never> {
        amplitudeSubject.eraseToAnyPublisher()
    }

    /// Fires once when the max-recording-length safeguard auto-stops the
    /// engine. Lets AppState surface a "Recording capped at 60s" message.
    nonisolated private let maxLengthHitSubject = PassthroughSubject<Void, Never>()
    nonisolated var maxLengthHits: AnyPublisher<Void, Never> {
        maxLengthHitSubject.eraseToAnyPublisher()
    }

    /// Tap consumer for converted (16 kHz mono Float32) buffers — the same
    /// buffers we write to the WAV. Used by SpeechRecognizer for the live
    /// preview while we record. Set/cleared from MainActor (AppState) around
    /// each recording cycle.
    nonisolated(unsafe) var bufferConsumer: (@Sendable (AVAudioPCMBuffer) -> Void)?

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

        // `engine.prepare()` BEFORE reading the input format. Prepare commits
        // the engine's audio path with the hardware, which is what forces the
        // OS to finish negotiating the Bluetooth profile (A2DP → HFP/HSP for
        // headsets with mic). Without this, `outputFormat(forBus:)` often
        // returns a half-baked format with the right sample rate but zero
        // channels — and passing that to `installTap` raises an Obj-C
        // exception inside AVFoundation that Swift can't catch, aborting the
        // process.
        engine.prepare()

        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Tightened validation: with Bluetooth we've seen formats come back
        // with sampleRate==16000 but channelCount==0 during the profile-switch
        // window. Both have to be non-zero or installTap will throw.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            logger.warning(
                "Input format not ready (sr=\(inputFormat.sampleRate, privacy: .public), ch=\(inputFormat.channelCount, privacy: .public)) — bailing before installTap."
            )
            throw AudioRecorderError.audioInputNotReady(
                sampleRate: inputFormat.sampleRate,
                channelCount: inputFormat.channelCount
            )
        }

        guard let proc = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else {
            throw AudioRecorderError.converterUnavailable
        }
        self.processingFormat = proc
        // Build the converter against the bus format we just read. It may get
        // rebuilt inside the tap callback if the actual buffer format differs
        // (Bluetooth can renegotiate after the engine starts).
        guard let conv = AVAudioConverter(from: inputFormat, to: proc) else {
            throw AudioRecorderError.converterUnavailable
        }
        self.converter = conv
        self.converterInputFormat = inputFormat
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

        let captureProc = proc
        let captureLogger = logger
        let captureQueue = queue
        let captureSubject = amplitudeSubject

        inputNode.removeTap(onBus: 0)
        // Pass `nil` for the format instead of our measured `inputFormat`.
        // AVFoundation's docs say nil means "use the bus's current format",
        // which avoids the strict format-equality check inside installTap
        // that's been throwing on Bluetooth. We adapt to whatever format
        // actually arrives by (re)building the converter inside the callback.
        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }

            // Lazy / adaptive converter: if the buffer's format doesn't match
            // what the converter was built for, rebuild it. Common with
            // Bluetooth: the first few buffers come in at one sample rate /
            // channel count, then the headset upgrades and subsequent buffers
            // arrive in a different format. Without this, the converter would
            // either error out every buffer or crash trying to read frames
            // outside the expected layout.
            let activeConverter: AVAudioConverter? = self.queue.sync {
                if let existing = self.converter,
                   let known = self.converterInputFormat,
                   formatsEqual(known, buffer.format) {
                    return existing
                }
                guard let rebuilt = AVAudioConverter(from: buffer.format, to: captureProc) else {
                    captureLogger.error(
                        "Failed to (re)build converter for buffer format sr=\(buffer.format.sampleRate, privacy: .public), ch=\(buffer.format.channelCount, privacy: .public)"
                    )
                    return nil
                }
                self.converter = rebuilt
                self.converterInputFormat = buffer.format
                captureLogger.info(
                    "Converter rebuilt for new buffer format (sr=\(buffer.format.sampleRate, privacy: .public), ch=\(buffer.format.channelCount, privacy: .public))"
                )
                return rebuilt
            }
            guard let captureConverter = activeConverter else { return }

            // Audio thread: convert → emit RMS → hand off to serial queue.
            let outputFrameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * captureProc.sampleRate / max(buffer.format.sampleRate, 1)
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

            // Forward the same converted buffer to whatever live consumer
            // is attached (SpeechRecognizer for the HUD preview). The consumer
            // closure is responsible for any further dispatching.
            if let consumer = self.bufferConsumer {
                consumer(outBuffer)
            }

            captureQueue.async { [weak self] in
                guard let self else { return }
                self.handleConvertedBuffer(outBuffer, rms: rms)
            }
        }

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
        // Cancel any pending max-length guard so it can't fire during a
        // subsequent recording.
        maxLengthTask?.cancel()
        maxLengthTask = nil

        // Remove the tap unconditionally. If the engine self-stopped during a
        // configuration-change (the input device renegotiated mid-session),
        // `engine.isRunning` may already be false — but the tap is still
        // installed on the input bus, and a follow-up `installTap` on the same
        // bus will throw an Obj-C exception ("nullptr == Tap()") and take the
        // process down. AVAudioEngine docs state removeTap is a no-op when no
        // tap is present, so this is safe in either state.
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        // Clear DSP state so the next start() comes up from a known-good
        // baseline. Cheap, and immune to any "engine ran into a bad state
        // during the last session" scenarios.
        engine.reset()
        audioFile = nil
        converter = nil
        converterInputFormat = nil
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
        // Cancel any prior guard so a stale task from an earlier (early-released)
        // recording can't fire during this new one and stop the engine
        // prematurely.
        maxLengthTask?.cancel()
        let limit = maxRecordingSeconds
        maxLengthTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.isRecording else { return }
                self.logger.warning("Max recording duration (\(limit, privacy: .public)s) hit — auto-stopping engine; URL remains valid.")
                if self.engine.isRunning {
                    self.engine.inputNode.removeTap(onBus: 0)
                    self.engine.stop()
                }
                self.maxLengthHitSubject.send()
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

/// Compares two `AVAudioFormat` instances on the dimensions that matter for
/// `AVAudioConverter` reuse: sample rate, channel count, and the common-format
/// (Float32 vs Int16 etc.). `AVAudioFormat`'s built-in `isEqual` also compares
/// channel-layout details which can spuriously differ across otherwise-
/// compatible buffers from the same Bluetooth device, so this is a coarser
/// "are these convertible the same way?" check.
fileprivate func formatsEqual(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
    return a.sampleRate == b.sampleRate
        && a.channelCount == b.channelCount
        && a.commonFormat == b.commonFormat
}
