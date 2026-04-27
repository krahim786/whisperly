import SwiftUI

struct SnippetsSettingsView: View {
    @ObservedObject var store: SnippetStore

    @State private var editing: Snippet?
    @State private var draftTrigger: String = ""
    @State private var draftExpansion: String = ""
    @State private var selection: Snippet.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Snippets")
                    .font(.headline)
                Spacer()
                Button {
                    beginAdd()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                Button(role: .destructive) {
                    if let selection { store.delete(id: selection) }
                } label: {
                    Label("Delete", systemImage: "minus")
                }
                .disabled(selection == nil)
            }
            .padding(12)

            Divider()

            HSplitView {
                Table(store.snippets, selection: $selection) {
                    TableColumn("Trigger", value: \.trigger)
                    TableColumn("Used") { snippet in
                        Text("\(snippet.useCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .width(50)
                }
                .frame(minWidth: 220)
                .onChange(of: selection) { _, new in
                    if let id = new, let snippet = store.snippets.first(where: { $0.id == id }) {
                        editing = snippet
                        draftTrigger = snippet.trigger
                        draftExpansion = snippet.expansion
                    } else {
                        editing = nil
                    }
                }

                detailPane
                    .frame(minWidth: 280)
            }
        }
        .frame(width: 640, height: 440)
    }

    @ViewBuilder
    private var detailPane: some View {
        if editing != nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("Trigger phrase")
                    .font(.subheadline.weight(.medium))
                TextField("e.g. insert signature", text: $draftTrigger)
                    .textFieldStyle(.roundedBorder)
                Text("Speak this phrase to expand the snippet. \"insert\" or \"type\" prefixes are recognized automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text("Expansion")
                    .font(.subheadline.weight(.medium))
                TextEditor(text: $draftExpansion)
                    .font(.system(.body, design: .default))
                    .border(.separator)
                    .frame(minHeight: 120)

                HStack {
                    Spacer()
                    Button("Save") { commit() }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(draftTrigger.trimmingCharacters(in: .whitespaces).isEmpty || draftExpansion.isEmpty)
                }
            }
            .padding(12)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.append")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Select a snippet to edit, or press + to add one.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func beginAdd() {
        editing = Snippet(trigger: "", expansion: "")
        draftTrigger = ""
        draftExpansion = ""
        selection = nil
    }

    private func commit() {
        let trigger = draftTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty, !draftExpansion.isEmpty else { return }

        if var existing = editing, store.snippets.contains(where: { $0.id == existing.id }) {
            existing.trigger = trigger
            existing.expansion = draftExpansion
            store.update(existing)
            selection = existing.id
        } else {
            store.add(trigger: trigger, expansion: draftExpansion)
            selection = store.snippets.first(where: { $0.trigger.lowercased() == trigger.lowercased() })?.id
        }
    }
}
