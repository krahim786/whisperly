import SwiftUI

struct AcknowledgementsView: View {
    @Environment(\.openURL) private var openURL

    private let entries: [Entry] = [
        Entry(
            name: "GRDB.swift",
            author: "Gwendal Roué",
            url: "https://github.com/groue/GRDB.swift",
            license: "MIT",
            description: "SQLite via Swift, with FTS5 + observation. Powers history search."
        )
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Whisperly stands on the shoulders of these open-source projects.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                ForEach(entries) { entry in
                    entryCard(entry)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Cloud services")
                        .font(.headline)
                    Text("Whisperly sends recorded audio to **Groq** for transcription and the resulting transcript to **Anthropic** for cleanup. Both calls go directly from your machine to the providers' APIs — no Whisperly servers in the middle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
        .frame(width: 480, height: 380)
        .navigationTitle("Acknowledgements")
    }

    @ViewBuilder
    private func entryCard(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.name)
                    .font(.headline)
                Spacer()
                Text(entry.license)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            Text("by \(entry.author)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(entry.description)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Link(entry.url, destination: URL(string: entry.url)!)
                .font(.caption2)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    struct Entry: Identifiable {
        let name: String
        let author: String
        let url: String
        let license: String
        let description: String
        var id: String { name }
    }
}

#Preview {
    AcknowledgementsView()
}
