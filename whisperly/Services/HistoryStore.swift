import Combine
import Foundation
import GRDB
import os

/// SQLite-backed (via GRDB) history of dictations with FTS5 search.
///
/// All access is async; callers can fire-and-forget inserts after a successful
/// dictation without blocking the user. The DatabaseQueue serializes I/O.
nonisolated final class HistoryStore: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.karim.whisperly", category: "HistoryStore")
    private let dbQueue: DatabaseQueue
    private let url: URL

    /// Emits whenever the table changes so observing UIs can refresh.
    nonisolated let changeSubject = PassthroughSubject<Void, Never>()

    init() throws {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = appSupport.appendingPathComponent("com.karim.whisperly", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        self.url = folder.appendingPathComponent("whisperly.sqlite3")

        var config = Configuration()
        config.label = "whisperly.history"
        self.dbQueue = try DatabaseQueue(path: url.path, configuration: config)

        try Self.migrator.migrate(dbQueue)
        logger.info("HistoryStore opened at \(self.url.path, privacy: .public)")
    }

    // MARK: - Migrations

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1_history_with_fts5") { db in
            try db.execute(sql: """
                CREATE TABLE history (
                    id TEXT PRIMARY KEY,
                    timestamp DATETIME NOT NULL,
                    mode TEXT NOT NULL,
                    target_app TEXT,
                    raw_transcript TEXT NOT NULL,
                    cleaned_text TEXT NOT NULL,
                    selection_input TEXT,
                    audio_duration_seconds REAL,
                    word_count INTEGER,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
            """)
            try db.execute(sql: "CREATE INDEX idx_history_timestamp ON history(timestamp DESC)")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE history_fts USING fts5(
                    cleaned_text, raw_transcript, target_app,
                    content='history', content_rowid='rowid'
                )
            """)

            // Triggers keep history_fts in sync. Without these the FTS table
            // never picks up new rows and search silently misses everything.
            try db.execute(sql: """
                CREATE TRIGGER history_ai AFTER INSERT ON history BEGIN
                    INSERT INTO history_fts(rowid, cleaned_text, raw_transcript, target_app)
                    VALUES (new.rowid, new.cleaned_text, new.raw_transcript, new.target_app);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER history_ad AFTER DELETE ON history BEGIN
                    INSERT INTO history_fts(history_fts, rowid, cleaned_text, raw_transcript, target_app)
                    VALUES ('delete', old.rowid, old.cleaned_text, old.raw_transcript, old.target_app);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER history_au AFTER UPDATE ON history BEGIN
                    INSERT INTO history_fts(history_fts, rowid, cleaned_text, raw_transcript, target_app)
                    VALUES ('delete', old.rowid, old.cleaned_text, old.raw_transcript, old.target_app);
                    INSERT INTO history_fts(rowid, cleaned_text, raw_transcript, target_app)
                    VALUES (new.rowid, new.cleaned_text, new.raw_transcript, new.target_app);
                END
            """)
        }

        return m
    }

    // MARK: - Writes

    @discardableResult
    func insert(_ entry: HistoryEntry) async throws -> HistoryEntry {
        let saved = try await dbQueue.write { db -> HistoryEntry in
            var copy = entry
            try copy.insert(db)
            return copy
        }
        changeSubject.send()
        return saved
    }

    /// Update the cleaned text for a single entry. Returns the original cleaned
    /// text from before the update so the caller can run a diff (e.g. for the
    /// dictionary learner).
    @discardableResult
    func updateCleanedText(id: String, newCleanedText: String) async throws -> String? {
        let original: String? = try await dbQueue.write { db -> String? in
            guard var entry = try HistoryEntry.filter(HistoryEntry.Columns.id == id).fetchOne(db) else {
                return nil
            }
            let before = entry.cleanedText
            entry.cleanedText = newCleanedText
            try entry.update(db)
            return before
        }
        if original != nil { changeSubject.send() }
        return original
    }

    func delete(id: String) async throws {
        let deleted = try await dbQueue.write { db -> Int in
            try HistoryEntry.filter(HistoryEntry.Columns.id == id).deleteAll(db)
        }
        if deleted > 0 { changeSubject.send() }
    }

    func clearAll() async throws {
        _ = try await dbQueue.write { db -> Int in
            try HistoryEntry.deleteAll(db)
        }
        changeSubject.send()
    }

    /// Drops entries older than `retentionDays` (counted from now).
    /// Returns the number of rows deleted.
    @discardableResult
    func enforceRetention(retentionDays: Int) async throws -> Int {
        guard retentionDays > 0 else { return 0 }
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
        let deleted = try await dbQueue.write { db -> Int in
            try HistoryEntry.filter(HistoryEntry.Columns.timestamp < cutoff).deleteAll(db)
        }
        if deleted > 0 {
            logger.info("Retention swept \(deleted, privacy: .public) entries older than \(retentionDays, privacy: .public) days")
            changeSubject.send()
        }
        return deleted
    }

    // MARK: - Reads

    enum DateRange: String, CaseIterable, Identifiable {
        case today
        case week
        case month
        case all

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .today: return "Today"
            case .week: return "This Week"
            case .month: return "This Month"
            case .all: return "All Time"
            }
        }

        func cutoffDate() -> Date? {
            let cal = Calendar.current
            switch self {
            case .today: return cal.startOfDay(for: Date())
            case .week: return cal.date(byAdding: .day, value: -7, to: Date())
            case .month: return cal.date(byAdding: .month, value: -1, to: Date())
            case .all: return nil
            }
        }
    }

    /// Search history entries. If `query` is empty, returns rows ordered by
    /// timestamp descending. Otherwise, runs the query through FTS5.
    func search(query: String, dateRange: DateRange, limit: Int = 500) async throws -> [HistoryEntry] {
        try await dbQueue.read { db in
            let cutoff = dateRange.cutoffDate()
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedQuery.isEmpty {
                var request = HistoryEntry.order(HistoryEntry.Columns.timestamp.desc)
                if let cutoff {
                    request = request.filter(HistoryEntry.Columns.timestamp >= cutoff)
                }
                return try request.limit(limit).fetchAll(db)
            }

            // FTS5 MATCH against the virtual table; join back to the main table
            // by rowid. Add a wildcard suffix so partial words match.
            let ftsQuery = Self.makeFTSQuery(trimmedQuery)
            let baseSQL = """
                SELECT history.* FROM history
                JOIN history_fts ON history_fts.rowid = history.rowid
                WHERE history_fts MATCH ?
                """

            var sql = baseSQL
            var args: [(any DatabaseValueConvertible)?] = [ftsQuery]
            if let cutoff {
                sql += " AND history.timestamp >= ?"
                args.append(cutoff)
            }
            sql += " ORDER BY history.timestamp DESC LIMIT ?"
            args.append(limit)

            return try HistoryEntry.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    /// Builds an FTS5 query string from raw user input. Strips characters
    /// that have special FTS5 meaning so users don't accidentally produce a
    /// syntax error, then appends `*` to each token for prefix matching.
    private static func makeFTSQuery(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
        let tokens = String(cleaned)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { "\($0)*" }
        return tokens.joined(separator: " ")
    }

    // MARK: - Export

    /// Writes all entries (newest-first) as a JSON array to `destination`.
    func exportJSON(to destination: URL) async throws {
        let entries = try await dbQueue.read { db in
            try HistoryEntry.order(HistoryEntry.Columns.timestamp.desc).fetchAll(db)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try data.write(to: destination, options: [.atomic])
    }

    var totalCount: Int {
        get async throws {
            try await dbQueue.read { db in
                try HistoryEntry.fetchCount(db)
            }
        }
    }

    // MARK: - Analytics

    /// Lightweight read of every entry's analytics-relevant fields. The full
    /// cleaned/raw text isn't needed for usage stats, so we return a slimmer
    /// projection instead of materializing every HistoryEntry.
    func analyticsRows() async throws -> [AnalyticsRow] {
        try await dbQueue.read { db in
            try Row
                .fetchAll(db, sql: "SELECT timestamp, target_app, word_count, audio_duration_seconds FROM history")
                .map { row in
                    AnalyticsRow(
                        timestamp: row["timestamp"],
                        targetApp: row["target_app"],
                        wordCount: row["word_count"],
                        audioDurationSeconds: row["audio_duration_seconds"]
                    )
                }
        }
    }

    nonisolated struct AnalyticsRow: Sendable {
        let timestamp: Date
        let targetApp: String?
        let wordCount: Int?
        let audioDurationSeconds: Double?
    }
}
