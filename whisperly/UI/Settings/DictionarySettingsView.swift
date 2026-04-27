import SwiftUI

struct DictionarySettingsView: View {
    @ObservedObject var store: DictionaryStore

    @State private var newTerm: String = ""
    @State private var newPhonetics: String = ""
    @State private var entrySelection: DictionaryEntry.ID?

    var body: some View {
        VStack(spacing: 0) {
            addBar
            Divider()
            entriesTable
            if !store.suggestions.isEmpty {
                Divider()
                suggestionsSection
            }
        }
        .frame(width: 640, height: 480)
    }

    // MARK: - Add bar

    private var addBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a term")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Term (e.g. CallVelocity)", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                TextField("Phonetic hints (comma-separated, e.g. \"call velocity\")", text: $newPhonetics)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addEntry() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Terms here are passed to Whisper to bias transcription, and to Claude Haiku to preserve exact spelling and casing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    // MARK: - Entries table

    private var entriesTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Vocabulary")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.entries.count) terms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    if let id = entrySelection { store.delete(id: id) }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(entrySelection == nil)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Table(store.entries, selection: $entrySelection) {
                TableColumn("Term", value: \.term)
                    .width(min: 120, ideal: 160)
                TableColumn("Phonetic hints") { entry in
                    Text(entry.phoneticHints.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                TableColumn("Source") { entry in
                    SourceBadge(source: entry.source, count: entry.confirmedCount)
                }
                .width(110)
            }
        }
    }

    // MARK: - Suggestions

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Suggested terms")
                    .font(.subheadline.weight(.medium))
                Text("(from your corrections in History)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.suggestions) { suggestion in
                        SuggestionChip(
                            suggestion: suggestion,
                            onAdd: { store.promoteSuggestion(id: suggestion.id) },
                            onDismiss: { store.dismissSuggestion(id: suggestion.id) }
                        )
                    }
                }
            }
        }
        .padding(12)
    }

    private func addEntry() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        let hints = newPhonetics
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        store.add(term: term, phoneticHints: hints)
        newTerm = ""
        newPhonetics = ""
    }
}

private struct SourceBadge: View {
    let source: DictionaryEntry.Source
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(source == .manual ? "Manual" : "Learned")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
            if source == .learned, count > 0 {
                Text("×\(count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color {
        source == .manual ? .blue : .green
    }
}

private struct SuggestionChip: View {
    let suggestion: DictionarySuggestion
    let onAdd: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(suggestion.term)
                .font(.callout.weight(.medium))
            Text("(\(suggestion.occurrences))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .help("Add to dictionary")
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}
