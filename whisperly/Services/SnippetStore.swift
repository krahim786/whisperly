import Combine
import Foundation
import os

/// JSON-backed snippet collection. Read at init, written on every mutation.
/// Single-file storage in `~/Library/Application Support/com.karim.whisperly/snippets.json`.
@MainActor
final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []

    private let logger = Logger(subsystem: "com.karim.whisperly", category: "SnippetStore")
    private let fileURL: URL

    init() {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = support.appendingPathComponent("com.karim.whisperly", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        self.fileURL = folder.appendingPathComponent("snippets.json")
        load()
    }

    func add(trigger: String, expansion: String) {
        let trimmedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTrigger.isEmpty, !expansion.isEmpty else { return }
        // Replace existing snippet with the same (case-insensitive) trigger.
        snippets.removeAll { $0.trigger.lowercased() == trimmedTrigger.lowercased() }
        snippets.append(Snippet(trigger: trimmedTrigger, expansion: expansion))
        snippets.sort { $0.trigger.lowercased() < $1.trigger.lowercased() }
        save()
    }

    func update(_ snippet: Snippet) {
        guard let idx = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[idx] = snippet
        save()
    }

    func delete(id: UUID) {
        snippets.removeAll { $0.id == id }
        save()
    }

    /// Increment usage stats. Called by AppState after a snippet expansion.
    func recordUse(id: UUID) {
        guard let idx = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[idx].useCount += 1
        snippets[idx].lastUsedAt = Date()
        save()
    }

    // MARK: - Disk I/O

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(SnippetsFile.self, from: data)
            snippets = file.snippets.sorted { $0.trigger.lowercased() < $1.trigger.lowercased() }
            logger.info("Loaded \(self.snippets.count, privacy: .public) snippets from disk")
        } catch {
            logger.error("Snippets load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        let file = SnippetsFile(snippets: snippets)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(file)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            logger.error("Snippets save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
