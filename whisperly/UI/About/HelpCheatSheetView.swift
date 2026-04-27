import SwiftUI

struct HelpCheatSheetView: View {
    @ObservedObject private var config = HotkeyConfig.shared

    private var hotkeyLabel: String {
        let mode = config.mode == .hold ? "Hold" : "Double-tap"
        return "\(mode) \(config.key.displayName)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Whisperly Quick Reference")
                    .font(.title2.weight(.semibold))

                section(title: "Activation") {
                    row(hotkeyLabel, "Start / stop dictation in any app")
                    row("Right-click menu bar icon", "Status, History, Settings, Quit")
                }

                section(title: "Modes — automatic") {
                    row("Nothing selected", "Dictation: speech is cleaned and pasted at the cursor")
                    row("Text selected", "Edit: speech becomes an instruction to rewrite the selection")
                    row("\"bullet list:\", \"email:\", etc.", "Command: formatted output")
                    row("\"insert <trigger>\"", "Snippet: pastes the expansion directly, no LLM")
                }

                section(title: "Windows") {
                    row("⌘Y", "Show History")
                    row("⌘,", "Settings")
                    row("Whisperly menu bar → Show Stats…", "Open the analytics dashboard")
                }

                section(title: "Settings tabs") {
                    row("General", "HUD, sounds, launch at login, onboarding, diagnostics")
                    row("Hotkey", "Activation mode + key chooser")
                    row("Snippets", "Trigger phrase → expansion text")
                    row("Dictionary", "Personal vocabulary + phonetic hints + suggestions")
                    row("History", "Retention, clear, export")
                    row("API Keys", "Groq + Anthropic")
                }

                section(title: "Tips") {
                    row("Pause < 2.5s", "Mid-utterance pauses are preserved")
                    row("Pause > 2.5s", "Trailing silence is dropped automatically")
                    row("Hold < 0.2s", "Treated as accidental — recording is cancelled")
                    row("Hold > 60s", "Capped automatically; whatever you said up to 60s gets transcribed")
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 520)
        .navigationTitle("Help")
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
            )
        }
    }

    @ViewBuilder
    private func row(_ left: String, _ right: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(left)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(minWidth: 160, alignment: .leading)
            Text(right)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
