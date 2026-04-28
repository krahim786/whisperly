import Foundation
import GRDB

/// One persisted dictation event. Mirrors the schema in HistoryStore.
///
/// Declared `nonisolated` so its `FetchableRecord` / `MutablePersistableRecord`
/// conformances (used inside GRDB's `Sendable` `db.write` / `db.read` closures
/// on the database queue) aren't inferred as `@MainActor` under the project's
/// `InferIsolatedConformances` upcoming feature.
nonisolated struct HistoryEntry: Identifiable, Equatable, Codable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case dictation
        case edit
        case command
        case translation

        var displayName: String {
            switch self {
            case .dictation: return "Dictation"
            case .edit: return "Edit"
            case .command: return "Command"
            case .translation: return "Translate"
            }
        }
    }

    var id: String
    var timestamp: Date
    var mode: Mode
    var targetApp: String?
    var rawTranscript: String
    var cleanedText: String
    var selectionInput: String?
    var audioDurationSeconds: Double?
    var wordCount: Int?
    var createdAt: Date?

    init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        mode: Mode,
        targetApp: String?,
        rawTranscript: String,
        cleanedText: String,
        selectionInput: String? = nil,
        audioDurationSeconds: Double? = nil,
        wordCount: Int? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.mode = mode
        self.targetApp = targetApp
        self.rawTranscript = rawTranscript
        self.cleanedText = cleanedText
        self.selectionInput = selectionInput
        self.audioDurationSeconds = audioDurationSeconds
        self.wordCount = wordCount
        self.createdAt = createdAt
    }
}

nonisolated extension HistoryEntry: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "history"

    enum Columns {
        static let id = Column("id")
        static let timestamp = Column("timestamp")
        static let mode = Column("mode")
        static let targetApp = Column("target_app")
        static let rawTranscript = Column("raw_transcript")
        static let cleanedText = Column("cleaned_text")
        static let selectionInput = Column("selection_input")
        static let audioDurationSeconds = Column("audio_duration_seconds")
        static let wordCount = Column("word_count")
        static let createdAt = Column("created_at")
    }

    init(row: Row) throws {
        // GRDB returns mode as a string; map back to enum.
        let modeString: String = row[Columns.mode]
        self.id = row[Columns.id]
        self.timestamp = row[Columns.timestamp]
        self.mode = Mode(rawValue: modeString) ?? .dictation
        self.targetApp = row[Columns.targetApp]
        self.rawTranscript = row[Columns.rawTranscript]
        self.cleanedText = row[Columns.cleanedText]
        self.selectionInput = row[Columns.selectionInput]
        self.audioDurationSeconds = row[Columns.audioDurationSeconds]
        self.wordCount = row[Columns.wordCount]
        self.createdAt = row[Columns.createdAt]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.timestamp] = timestamp
        container[Columns.mode] = mode.rawValue
        container[Columns.targetApp] = targetApp
        container[Columns.rawTranscript] = rawTranscript
        container[Columns.cleanedText] = cleanedText
        container[Columns.selectionInput] = selectionInput
        container[Columns.audioDurationSeconds] = audioDurationSeconds
        container[Columns.wordCount] = wordCount
        // created_at is filled in by SQLite's DEFAULT CURRENT_TIMESTAMP on insert.
    }
}
