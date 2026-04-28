import SwiftUI

struct HistoryWindowView: View {
    @StateObject private var vm: HistoryViewModel

    init(store: HistoryStore, inserter: TextInserter, dictionary: DictionaryStore?) {
        _vm = StateObject(wrappedValue: HistoryViewModel(store: store, inserter: inserter, dictionary: dictionary))
    }

    @State private var selection: HistoryEntry.ID?
    @State private var entryBeingEdited: HistoryEntry?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 420)
        .navigationTitle("Whisperly History")
        .onAppear { vm.load() }
        .alert("History error", isPresented: .constant(vm.errorMessage != nil), presenting: vm.errorMessage) { _ in
            Button("OK") { vm.errorMessage = nil }
        } message: { msg in
            Text(msg)
        }
        .sheet(item: $entryBeingEdited) { entry in
            HistoryEditSheet(entry: entry) { newText in
                vm.updateCleanedText(entry, to: newText)
                entryBeingEdited = nil
            } cancel: {
                entryBeingEdited = nil
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search history…", text: $vm.query)
                .textFieldStyle(.roundedBorder)
            Picker("Range", selection: $vm.dateRange) {
                ForEach(HistoryStore.DateRange.allCases) { range in
                    Text(range.displayName).tag(range)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 140)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if vm.entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(emptyStateText)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(vm.entries, selection: $selection) {
                TableColumn("Date") { entry in
                    Text(Self.dateFormatter.string(from: entry.timestamp))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 140, max: 180)

                TableColumn("App") { entry in
                    Text(entry.targetApp ?? "—")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .width(min: 80, ideal: 110, max: 160)

                TableColumn("Mode") { entry in
                    ModeBadge(mode: entry.mode)
                }
                .width(min: 70, ideal: 80, max: 100)

                TableColumn("Preview") { entry in
                    Text(entry.cleanedText)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(entry.cleanedText)
                }
            }
            .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
                if let id = ids.first, let entry = vm.entries.first(where: { $0.id == id }) {
                    Button("Copy") { vm.copy(entry) }
                    Button("Re-paste at cursor") { Task { await vm.paste(entry) } }
                    Button("Edit cleaned text…") { entryBeingEdited = entry }
                    Divider()
                    Button("Delete", role: .destructive) { vm.delete(entry) }
                }
            } primaryAction: { ids in
                if let id = ids.first, let entry = vm.entries.first(where: { $0.id == id }) {
                    Task { await vm.paste(entry) }
                }
            }
            .onChange(of: selection) { _, new in
                guard let id = new, let entry = vm.entries.first(where: { $0.id == id }) else { return }
                vm.copy(entry)
            }
        }
    }

    private var emptyStateText: String {
        if !vm.query.isEmpty {
            return "No matches for \"\(vm.query)\""
        }
        switch vm.dateRange {
        case .today: return "Nothing dictated today yet."
        case .week: return "Nothing dictated this week yet."
        case .month: return "Nothing dictated this month yet."
        case .all: return "No dictation history yet."
        }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

private struct ModeBadge: View {
    let mode: HistoryEntry.Mode

    var body: some View {
        Text(mode.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.18), in: Capsule())
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        switch mode {
        case .dictation: return .blue
        case .edit: return .orange
        case .command: return .purple
        case .translation: return .teal
        }
    }
}

private struct HistoryEditSheet: View {
    let entry: HistoryEntry
    let save: (String) -> Void
    let cancel: () -> Void

    @State private var draft: String

    init(entry: HistoryEntry, save: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.entry = entry
        self.save = save
        self.cancel = cancel
        _draft = State(initialValue: entry.cleanedText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit cleaned text")
                .font(.headline)
            Text("Edits help Whisperly learn your vocabulary — new words you add to the cleaned text become dictionary suggestions after a few corrections.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $draft)
                .font(.body)
                .border(.separator)
                .frame(minWidth: 480, minHeight: 220)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                Button("Save") { save(draft) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(draft == entry.cleanedText)
            }
        }
        .padding(16)
        .frame(minWidth: 520)
    }
}
