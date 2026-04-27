import Foundation
import os

/// Diffs an "original cleaned text" against a user-corrected version of the
/// same dictation and asks the dictionary store to record any words that
/// appear only in the corrected version. Repeated observations promote a
/// suggestion into a real dictionary entry.
nonisolated enum DictionaryLearner {
    private static let logger = Logger(subsystem: "com.karim.whisperly", category: "DictionaryLearner")

    /// Returns the candidate terms: tokens that appear in `corrected` but not
    /// in `original`. Filters out short tokens, common stop-words, and pure
    /// punctuation — we want proper nouns and unusual spellings.
    static func candidates(original: String, corrected: String) -> [String] {
        let originalTokens = Set(tokens(in: original).map { $0.lowercased() })
        let correctedTokens = tokens(in: corrected)
        let seen = NSMutableOrderedSet()
        for token in correctedTokens {
            let lower = token.lowercased()
            if originalTokens.contains(lower) { continue }
            if !isInteresting(token) { continue }
            seen.add(token)
        }
        return seen.array as? [String] ?? []
    }

    /// Convenience: observe a correction and record candidates with the store.
    @MainActor
    static func observeCorrection(
        original: String,
        corrected: String,
        store: DictionaryStore
    ) {
        let cands = candidates(original: original, corrected: corrected)
        guard !cands.isEmpty else { return }
        logger.info("Correction observed; candidate terms: \(cands.joined(separator: ", "), privacy: .public)")
        for c in cands {
            store.recordSuggestion(term: c)
        }
    }

    // MARK: - Helpers

    private static func tokens(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                current.append(ch)
            } else {
                if !current.isEmpty { result.append(current); current = "" }
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// A token is "interesting" if it looks like a proper noun, identifier, or
    /// rare term: 3+ chars and either has at least one uppercase letter (likely
    /// a proper noun or CamelCase term) or is not in the common stop-word set.
    private static func isInteresting(_ token: String) -> Bool {
        guard token.count >= 3 else { return false }
        if token.contains(where: { $0.isUppercase }) {
            return true
        }
        let lower = token.lowercased()
        return !commonWords.contains(lower)
    }

    /// A small stop-word set so we don't flood the suggestion list with
    /// "the", "and", etc. Intentionally compact — the goal isn't perfect
    /// linguistics, it's filtering obviously-uninteresting words.
    private static let commonWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "then", "than", "that",
        "this", "these", "those", "is", "are", "was", "were", "be", "been",
        "being", "have", "has", "had", "do", "does", "did", "of", "to", "in",
        "on", "at", "by", "for", "with", "about", "as", "from", "up", "down",
        "out", "into", "over", "under", "i", "me", "my", "mine", "you", "your",
        "yours", "he", "him", "his", "she", "her", "hers", "we", "us", "our",
        "they", "them", "their", "it", "its", "what", "which", "who", "whom",
        "when", "where", "why", "how", "so", "no", "not", "yes", "all", "any",
        "some", "more", "most", "less", "many", "much", "few", "very", "too",
        "just", "only", "even", "also", "well", "now", "here", "there", "can",
        "could", "would", "should", "may", "might", "will", "shall", "must",
        "ok", "okay",
    ]
}
