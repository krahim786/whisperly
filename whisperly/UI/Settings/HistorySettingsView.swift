import SwiftUI
import UniformTypeIdentifiers

struct HistorySettingsView: View {
    let store: HistoryStore?

    @ObservedObject private var config = HotkeyConfig.shared
    @State private var totalCount: Int = 0
    @State private var showingClearConfirm = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        Form {
            Section("History") {
                Toggle("Save dictation history", isOn: $config.historyEnabled)
                Stepper(value: $config.historyRetentionDays, in: 1...365) {
                    HStack {
                        Text("Retain history for")
                        Text("\(config.historyRetentionDays) days")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!config.historyEnabled)
                Text("Older entries are removed at app launch and after each new dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Text("\(totalCount) entries stored")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Export…") { exportJSON() }
                        .disabled(store == nil || totalCount == 0)
                    Button("Clear All…", role: .destructive) { showingClearConfirm = true }
                        .disabled(store == nil || totalCount == 0)
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(statusIsError ? .red : .green)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 360)
        .task { await refreshCount() }
        .confirmationDialog(
            "Delete all dictation history?",
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes \(totalCount) entries and cannot be undone.")
        }
    }

    private func refreshCount() async {
        guard let store else { return }
        do {
            totalCount = try await store.totalCount
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func clearAll() {
        guard let store else { return }
        Task {
            do {
                try await store.clearAll()
                statusIsError = false
                statusMessage = "History cleared"
                await refreshCount()
            } catch {
                statusIsError = true
                statusMessage = error.localizedDescription
            }
        }
    }

    private func exportJSON() {
        guard let store else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "whisperly-history-\(Self.fileDateFormatter.string(from: Date())).json"
        panel.canCreateDirectories = true
        panel.title = "Export Whisperly History"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await store.exportJSON(to: url)
                statusIsError = false
                statusMessage = "Exported to \(url.lastPathComponent)"
            } catch {
                statusIsError = true
                statusMessage = error.localizedDescription
            }
        }
    }

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
