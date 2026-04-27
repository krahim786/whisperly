import SwiftUI

struct FirstDictationStep: View {
    @ObservedObject var appState: AppState
    let onFinish: () -> Void
    let onBack: () -> Void

    @ObservedObject private var config = HotkeyConfig.shared
    @State private var practiceText: String = ""

    private var hotkeySummary: String {
        let mode = config.mode == .hold ? "Hold" : "Double-tap"
        return "\(mode) \(config.key.displayName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Try your first dictation")
                    .font(.title2.weight(.semibold))
                Text("Click in the text field below, then \(hotkeySummary.lowercased()) and say a sentence — anything you'd type. Whisperly will polish it and paste it where your cursor is.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Practice field")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $practiceText)
                    .font(.body)
                    .border(.separator)
                    .frame(minHeight: 140)
                if !practiceText.isEmpty {
                    Label("Looks good — your dictation pasted here.", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }

            HStack(spacing: 12) {
                statePill
                Spacer()
                Text(hotkeySummary)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }

            Spacer(minLength: 0)
            HStack {
                Button("Back") { onBack() }
                Spacer()
                Button("Skip for now") { onFinish() }
                Button("Done") { onFinish() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    @ViewBuilder
    private var statePill: some View {
        let (label, color, symbol) = pillContent(for: appState.phase)
        Label(label, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private func pillContent(for phase: AppState.Phase) -> (String, Color, String) {
        switch phase {
        case .idle: return ("Ready", .secondary, "mic")
        case .recording: return ("Recording", .red, "mic.fill")
        case .transcribing: return ("Transcribing", .blue, "waveform")
        case .cleaning: return ("Polishing", .blue, "sparkles")
        case .pasting: return ("Pasting", .green, "checkmark.circle.fill")
        case .error: return ("Error", .orange, "exclamationmark.triangle.fill")
        }
    }
}
