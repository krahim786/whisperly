import SwiftUI

struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
                .padding(.top, 8)
            Text("Welcome to Whisperly")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text("Hold a hotkey, speak naturally, and Whisperly turns your voice into polished text — pasted right into whatever app you're using.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            VStack(alignment: .leading, spacing: 10) {
                bullet("mic.fill", "Cloud-powered transcription via Groq Whisper")
                bullet("sparkles", "Cleanup with Claude Haiku 4.5")
                bullet("text.cursor", "Selection-aware editing — speak instructions to rewrite highlighted text")
                bullet("clock.arrow.circlepath", "Searchable history of every dictation")
            }
            .padding(.top, 8)

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Get started") { onContinue() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(text)
                .foregroundStyle(.primary)
            Spacer()
        }
    }
}
