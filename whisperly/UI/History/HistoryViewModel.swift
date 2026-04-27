import AppKit
import Combine
import Foundation
import os
import SwiftUI

/// Drives the History window: holds the search query, date filter, and the
/// fetched entries. Talks to `HistoryStore` for queries and `TextInserter`
/// for re-paste.
@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var dateRange: HistoryStore.DateRange = .all
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var isLoading: Bool = false
    @Published var errorMessage: String?

    private let store: HistoryStore
    private let inserter: TextInserter
    private let dictionary: DictionaryStore?
    private let logger = Logger(subsystem: "com.karim.whisperly", category: "HistoryVM")

    private var cancellables = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?

    init(store: HistoryStore, inserter: TextInserter, dictionary: DictionaryStore?) {
        self.store = store
        self.inserter = inserter
        self.dictionary = dictionary

        // Debounced search: re-fetch when the query stabilizes.
        $query
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        $dateRange
            .removeDuplicates()
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        // Re-fetch whenever the store reports a change (insert / delete /
        // clear / retention sweep).
        store.changeSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.reload() }
            .store(in: &cancellables)
    }

    func load() {
        reload()
    }

    func copy(_ entry: HistoryEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.cleanedText, forType: .string)
    }

    /// Re-paste a history entry into whatever app the user was last in.
    /// Hides the history window first so the previous app comes forward and
    /// receives the synthesized ⌘V.
    func paste(_ entry: HistoryEntry) async {
        // Send our own app to the back so the previously frontmost app
        // returns to focus, then give it a beat to settle before paste.
        NSApp.hide(nil)
        try? await Task.sleep(nanoseconds: 120_000_000)
        await inserter.paste(entry.cleanedText)
    }

    /// User edited the cleaned text for an entry. Persist it and run the
    /// dictionary learner over the diff so any new vocabulary gets surfaced.
    func updateCleanedText(_ entry: HistoryEntry, to newText: String) {
        let trimmed = newText
        guard trimmed != entry.cleanedText else { return }
        Task { [store, dictionary] in
            do {
                if let original = try await store.updateCleanedText(id: entry.id, newCleanedText: trimmed) {
                    if let dictionary {
                        await MainActor.run {
                            DictionaryLearner.observeCorrection(
                                original: original,
                                corrected: trimmed,
                                store: dictionary
                            )
                        }
                    }
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func delete(_ entry: HistoryEntry) {
        Task {
            do {
                try await store.delete(id: entry.id)
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func reload() {
        loadTask?.cancel()
        let q = query
        let r = dateRange
        isLoading = true
        loadTask = Task { [store] in
            do {
                let result = try await store.search(query: q, dateRange: r)
                if Task.isCancelled { return }
                self.entries = result
                self.isLoading = false
            } catch {
                if Task.isCancelled { return }
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}
