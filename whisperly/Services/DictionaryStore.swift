import Combine
import Foundation
import os

/// JSON-backed dictionary of user vocabulary. Held entirely in memory; Combine
/// publishers let downstream consumers (Haiku prompts, Whisper biasing) react.
///
/// Format on disk: `dictionary.json` with `entries`. Suggestions live in a
/// sibling `dictionary_suggestions.json` so the dictionary file stays clean.
@MainActor
final class DictionaryStore: ObservableObject {
    @Published private(set) var entries: [DictionaryEntry] = []
    @Published private(set) var suggestions: [DictionarySuggestion] = []

    private let logger = Logger(subsystem: "com.karim.whisperly", category: "DictionaryStore")
    private let entriesURL: URL
    private let suggestionsURL: URL

    /// After this many independent observations, a suggestion is auto-promoted
    /// to a `learned` dictionary entry.
    static let autoPromoteThreshold = 3

    init() {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = support.appendingPathComponent("com.karim.whisperly", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        self.entriesURL = folder.appendingPathComponent("dictionary.json")
        self.suggestionsURL = folder.appendingPathComponent("dictionary_suggestions.json")
        loadEntries()
        loadSuggestions()
    }

    // MARK: - Entries

    func add(term: String, phoneticHints: [String] = []) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Replace existing entry with the same term (case-sensitive — we want
        // to preserve the casing the user typed).
        entries.removeAll { $0.term == trimmed }
        let cleanedHints = phoneticHints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        entries.append(DictionaryEntry(term: trimmed, phoneticHints: cleanedHints, source: .manual))
        entries.sort { $0.term.lowercased() < $1.term.lowercased() }
        saveEntries()
    }

    func update(_ entry: DictionaryEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx] = entry
        saveEntries()
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        saveEntries()
    }

    /// Top `n` terms by source priority (manual first, then learned by count).
    /// Used as the Whisper biasing prompt — Groq accepts ~244 tokens here, so
    /// we keep it small.
    func topTermsForBiasing(limit: Int = 20) -> [String] {
        let sorted = entries.sorted { lhs, rhs in
            if lhs.source != rhs.source {
                return lhs.source == .manual && rhs.source == .learned
            }
            return lhs.confirmedCount > rhs.confirmedCount
        }
        return Array(sorted.prefix(limit).map { $0.term })
    }

    /// JSON representation suitable for inlining into a Haiku system prompt.
    /// Compact form so it doesn't bloat the prompt unnecessarily.
    func jsonForPrompt() -> String {
        struct PromptEntry: Encodable {
            let term: String
            let phoneticHints: [String]
        }
        let payload = entries.map { PromptEntry(term: $0.term, phoneticHints: $0.phoneticHints) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }

    // MARK: - Suggestions (learner)

    func recordSuggestion(term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Skip if already in the dictionary.
        if entries.contains(where: { $0.term == trimmed }) { return }

        if let idx = suggestions.firstIndex(where: { $0.term == trimmed }) {
            suggestions[idx].occurrences += 1
            suggestions[idx].lastSeen = Date()
            // Auto-promote if we've met the threshold.
            if suggestions[idx].occurrences >= Self.autoPromoteThreshold {
                let promoted = suggestions.remove(at: idx)
                let entry = DictionaryEntry(
                    term: promoted.term,
                    addedAt: Date(),
                    source: .learned,
                    confirmedCount: promoted.occurrences
                )
                entries.append(entry)
                entries.sort { $0.term.lowercased() < $1.term.lowercased() }
                logger.info("Auto-promoted suggestion '\(promoted.term, privacy: .public)' after \(promoted.occurrences, privacy: .public) confirmations")
                saveEntries()
                saveSuggestions()
                return
            }
        } else {
            suggestions.append(DictionarySuggestion(term: trimmed))
        }
        saveSuggestions()
    }

    /// User explicitly accepts a suggestion — promote it to a manual entry now.
    func promoteSuggestion(id: UUID) {
        guard let idx = suggestions.firstIndex(where: { $0.id == id }) else { return }
        let s = suggestions.remove(at: idx)
        let entry = DictionaryEntry(
            term: s.term,
            addedAt: Date(),
            source: .learned,
            confirmedCount: s.occurrences
        )
        entries.append(entry)
        entries.sort { $0.term.lowercased() < $1.term.lowercased() }
        saveEntries()
        saveSuggestions()
    }

    func dismissSuggestion(id: UUID) {
        suggestions.removeAll { $0.id == id }
        saveSuggestions()
    }

    var pendingSuggestionCount: Int { suggestions.count }

    // MARK: - Disk I/O

    private func loadEntries() {
        guard FileManager.default.fileExists(atPath: entriesURL.path) else { return }
        do {
            let data = try Data(contentsOf: entriesURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(DictionaryFile.self, from: data)
            entries = file.entries.sorted { $0.term.lowercased() < $1.term.lowercased() }
            logger.info("Loaded \(self.entries.count, privacy: .public) dictionary entries")
        } catch {
            logger.error("Dictionary load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveEntries() {
        let file = DictionaryFile(entries: entries)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(file)
            try data.write(to: entriesURL, options: [.atomic])
        } catch {
            logger.error("Dictionary save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadSuggestions() {
        guard FileManager.default.fileExists(atPath: suggestionsURL.path) else { return }
        do {
            let data = try Data(contentsOf: suggestionsURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(SuggestionsFile.self, from: data)
            suggestions = file.suggestions
        } catch {
            logger.error("Suggestions load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveSuggestions() {
        let file = SuggestionsFile(suggestions: suggestions)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(file)
            try data.write(to: suggestionsURL, options: [.atomic])
        } catch {
            logger.error("Suggestions save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
