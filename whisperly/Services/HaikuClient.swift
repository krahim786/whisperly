import Foundation
import os

enum HaikuClientError: LocalizedError {
    case missingAPIKey
    case unauthorized
    case rateLimited
    case server(Int, String)
    case network(any Error)
    case decoding
    case empty

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Anthropic API key is missing. Add it in Settings."
        case .unauthorized: return "Anthropic API key was rejected (401)."
        case .rateLimited: return "Anthropic is rate-limiting (429). Try again."
        case .server(let code, let body): return "Anthropic server error (\(code)): \(body)"
        case .network(let error): return "Network error: \(error.localizedDescription)"
        case .decoding: return "Could not parse Anthropic response."
        case .empty: return "Anthropic returned an empty response."
        }
    }
}

/// Calls Claude Haiku 4.5 with the dictation cleanup prompt.
/// The system block uses prompt caching so the prompt prefix is reused across calls
/// — only the small user message changes per dictation.
nonisolated final class HaikuClient: Sendable {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model = "claude-haiku-4-5-20251001"
    private let anthropicVersion = "2023-06-01"
    private let logger = Logger(subsystem: "com.karim.whisperly", category: "HaikuClient")
    private let session: URLSession
    private let keychain: KeychainService

    init(keychain: KeychainService) {
        self.keychain = keychain
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    func cleanup(transcript: String, appName: String) async throws -> String {
        guard let apiKey = keychain.load(key: KeychainService.anthropicAPIKey), !apiKey.isEmpty else {
            throw HaikuClientError.missingAPIKey
        }

        let systemPrompt = DictationPrompt.system()
        let userMessage = "Target app: \(appName)\nRaw transcript: \(transcript)"

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": [
                [
                    "type": "text",
                    "text": systemPrompt,
                    "cache_control": ["type": "ephemeral"],
                ]
            ],
            "messages": [
                [
                    "role": "user",
                    "content": userMessage,
                ]
            ],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HaikuClientError.network(error)
        }
        let elapsed = Date().timeIntervalSince(start)

        guard let http = response as? HTTPURLResponse else {
            throw HaikuClientError.decoding
        }
        switch http.statusCode {
        case 200:
            break
        case 401:
            throw HaikuClientError.unauthorized
        case 429:
            throw HaikuClientError.rateLimited
        default:
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw HaikuClientError.server(http.statusCode, bodyStr)
        }

        struct AnthropicResponse: Decodable {
            struct Block: Decodable {
                let type: String
                let text: String?
            }
            struct Usage: Decodable {
                let input_tokens: Int?
                let output_tokens: Int?
                let cache_creation_input_tokens: Int?
                let cache_read_input_tokens: Int?
            }
            let content: [Block]
            let usage: Usage?
        }

        let decoded: AnthropicResponse
        do {
            decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        } catch {
            logger.error("Anthropic decode error: \(error.localizedDescription, privacy: .public)")
            throw HaikuClientError.decoding
        }

        let cacheCreate = decoded.usage?.cache_creation_input_tokens ?? 0
        let cacheRead = decoded.usage?.cache_read_input_tokens ?? 0
        let input = decoded.usage?.input_tokens ?? 0
        let output = decoded.usage?.output_tokens ?? 0
        logger.info("Haiku cleanup \(String(format: "%.2f", elapsed))s — input:\(input) output:\(output) cache_create:\(cacheCreate) cache_read:\(cacheRead)")

        guard let text = decoded.content.first(where: { $0.type == "text" })?.text,
              !text.isEmpty else {
            throw HaikuClientError.empty
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
