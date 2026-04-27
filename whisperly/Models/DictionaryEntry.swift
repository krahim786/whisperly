import Foundation

/// A user-vocabulary term we want preserved verbatim by both Whisper (via
/// the audio prompt biasing parameter) and Claude Haiku (via the dictionary
/// JSON injected into all three system prompts).
///
/// `phoneticHints` are the way the user typically says the term aloud (e.g.
/// "call velocity" → "CallVelocity"). They help disambiguate when Whisper
/// might otherwise transcribe the phonetic variant.
nonisolated struct DictionaryEntry: Identifiable, Equatable, Codable, Sendable {
    enum Source: String, Codable, Sendable {
        case manual
        case learned
    }

    var id: UUID
    var term: String
    var phoneticHints: [String]
    var addedAt: Date
    var source: Source
    var confirmedCount: Int

    init(
        id: UUID = UUID(),
        term: String,
        phoneticHints: [String] = [],
        addedAt: Date = Date(),
        source: Source = .manual,
        confirmedCount: Int = 0
    ) {
        self.id = id
        self.term = term
        self.phoneticHints = phoneticHints
        self.addedAt = addedAt
        self.source = source
        self.confirmedCount = confirmedCount
    }
}

nonisolated struct DictionaryFile: Codable, Sendable {
    var version: Int
    var entries: [DictionaryEntry]

    init(version: Int = 1, entries: [DictionaryEntry] = []) {
        self.version = version
        self.entries = entries
    }
}

/// Pending learner candidates — terms that have appeared in user corrections
/// but haven't met the auto-promote threshold yet. Persisted alongside the
/// dictionary so they survive restarts.
nonisolated struct DictionarySuggestion: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var term: String
    var occurrences: Int
    var firstSeen: Date
    var lastSeen: Date

    init(id: UUID = UUID(), term: String, occurrences: Int = 1, firstSeen: Date = Date(), lastSeen: Date = Date()) {
        self.id = id
        self.term = term
        self.occurrences = occurrences
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

nonisolated struct SuggestionsFile: Codable, Sendable {
    var version: Int
    var suggestions: [DictionarySuggestion]

    init(version: Int = 1, suggestions: [DictionarySuggestion] = []) {
        self.version = version
        self.suggestions = suggestions
    }
}
