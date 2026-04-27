import Foundation

/// A user-defined text expansion. When the user dictates a phrase that matches
/// `trigger` (per `SnippetMatcher`), we paste `expansion` directly without
/// touching the LLM — fast and predictable.
nonisolated struct Snippet: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var trigger: String
    var expansion: String
    var useCount: Int
    var addedAt: Date
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        trigger: String,
        expansion: String,
        useCount: Int = 0,
        addedAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.useCount = useCount
        self.addedAt = addedAt
        self.lastUsedAt = lastUsedAt
    }
}

/// On-disk envelope so we can evolve the schema without breaking older files.
nonisolated struct SnippetsFile: Codable, Sendable {
    var version: Int
    var snippets: [Snippet]

    init(version: Int = 1, snippets: [Snippet] = []) {
        self.version = version
        self.snippets = snippets
    }
}
