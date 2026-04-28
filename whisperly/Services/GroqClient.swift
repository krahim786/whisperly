import Foundation
import os

enum GroqClientError: LocalizedError {
    case missingAPIKey
    case invalidAudioFile
    case unauthorized
    case rateLimited
    case server(Int, String)
    case network(any Error)
    case decoding

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Groq API key is missing. Add it in Settings."
        case .invalidAudioFile: return "Recorded audio file could not be read."
        case .unauthorized: return "Groq API key was rejected (401)."
        case .rateLimited: return "Groq is rate-limiting (429). Try again."
        case .server(let code, let body): return "Groq server error (\(code)): \(body)"
        case .network(let error): return "Network error: \(error.localizedDescription)"
        case .decoding: return "Could not parse Groq response."
        }
    }
}

/// Wraps Groq's OpenAI-compatible audio transcription endpoint.
/// Uses `whisper-large-v3-turbo` and returns the raw transcript text.
nonisolated final class GroqClient: Sendable {
    private let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    private let model = "whisper-large-v3-turbo"
    private let logger = Logger(subsystem: "com.karim.whisperly", category: "GroqClient")
    private let session: URLSession
    private let keychain: KeychainService

    init(keychain: KeychainService) {
        self.keychain = keychain
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// Cheap auth check used by onboarding before letting the user proceed.
    /// Hits `/v1/models` with the supplied key — returns true on 200, throws
    /// `unauthorized` on 401, or `network` for transport errors.
    func validate(apiKey: String) async throws -> Bool {
        let url = URL(string: "https://api.groq.com/openai/v1/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GroqClientError.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw GroqClientError.decoding }
        switch http.statusCode {
        case 200: return true
        case 401, 403: throw GroqClientError.unauthorized
        case 429: throw GroqClientError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GroqClientError.server(http.statusCode, body)
        }
    }

    /// Transcribe an audio file. `biasingTerms` are passed as Whisper's `prompt`
    /// parameter to bias the STT output toward the user's vocabulary — proper
    /// nouns, product names, etc. Whisper accepts up to 244 prompt tokens; we
    /// cap the joined string length defensively at 1024 chars to stay under that.
    ///
    /// `languageCode` is the ISO 639-1 hint for Whisper. Pass `nil` to let
    /// Whisper auto-detect from the audio (used by translation mode when
    /// the user has selected "Auto-detect" as the speaking language).
    /// Defaults to "en" so existing English-only users see no change.
    func transcribe(audioURL: URL, biasingTerms: [String] = [], languageCode: String? = "en") async throws -> String {
        guard let apiKey = keychain.load(key: KeychainService.groqAPIKey), !apiKey.isEmpty else {
            throw GroqClientError.missingAPIKey
        }
        guard let audioData = try? Data(contentsOf: audioURL) else {
            throw GroqClientError.invalidAudioFile
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeMultipartBody(
            boundary: boundary,
            audioData: audioData,
            filename: audioURL.lastPathComponent,
            biasingPrompt: makeBiasingPrompt(from: biasingTerms),
            languageCode: languageCode
        )

        let start = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GroqClientError.network(error)
        }
        let elapsed = Date().timeIntervalSince(start)
        logger.info("Groq transcribe \(audioData.count) bytes → \(String(format: "%.2f", elapsed))s")

        guard let http = response as? HTTPURLResponse else {
            throw GroqClientError.decoding
        }

        switch http.statusCode {
        case 200:
            break
        case 401:
            throw GroqClientError.unauthorized
        case 429:
            throw GroqClientError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GroqClientError.server(http.statusCode, body)
        }

        struct TranscriptionResponse: Decodable {
            let text: String
        }
        do {
            let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
            return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.error("Groq decode error: \(error.localizedDescription, privacy: .public)")
            throw GroqClientError.decoding
        }
    }

    private func makeMultipartBody(boundary: String, audioData: Data, filename: String, biasingPrompt: String?, languageCode: String?) -> Data {
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField("model", model)
        appendField("response_format", "json")
        appendField("temperature", "0")
        // Omit `language` for auto-detect; pass the ISO code otherwise.
        if let languageCode, !languageCode.isEmpty {
            appendField("language", languageCode)
        }
        if let biasingPrompt, !biasingPrompt.isEmpty {
            appendField("prompt", biasingPrompt)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    /// Builds Whisper's `prompt` parameter from user vocabulary. Whisper
    /// interprets this as transcription context, biasing the model toward
    /// the listed words/spellings. Comma-separated form works well in practice.
    private func makeBiasingPrompt(from terms: [String]) -> String? {
        let cleaned = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        let joined = cleaned.joined(separator: ", ")
        return joined.count > 1024 ? String(joined.prefix(1024)) : joined
    }
}
