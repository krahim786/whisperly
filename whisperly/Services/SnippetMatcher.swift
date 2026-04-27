import Foundation

/// Decides whether a transcript should bypass the LLM and expand directly to
/// a snippet's text. Recognizes either a bare trigger phrase or one prefixed
/// by "insert" / "type" — both common ways the user might dictate.
///
/// Matching is case-insensitive and ignores trailing punctuation that Whisper
/// commonly adds (period, comma, exclamation, question mark).
nonisolated enum SnippetMatcher {
    private static let prefixVerbs = ["insert", "type"]
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,!?;:")

    static func match(transcript: String, in snippets: [Snippet]) -> Snippet? {
        let normalized = normalize(transcript)
        guard !normalized.isEmpty else { return nil }

        // Strip optional "insert"/"type" prefix.
        let stripped = stripPrefixVerb(normalized)

        return snippets.first { snippet in
            let trigger = normalize(snippet.trigger)
            return stripped == trigger
        }
    }

    private static func normalize(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Trim trailing punctuation.
        while let last = t.unicodeScalars.last, trailingPunctuation.contains(last) {
            t.removeLast()
        }
        return t.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripPrefixVerb(_ text: String) -> String {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
              prefixVerbs.contains(String(parts[0])) else {
            return text
        }
        return String(parts[1]).trimmingCharacters(in: .whitespaces)
    }
}
