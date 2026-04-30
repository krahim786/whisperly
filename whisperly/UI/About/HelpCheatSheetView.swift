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
                    row("Hold \(hotkeyLabel) + Shift", "Dictate, then pick a transformation from the action menu")
                    row("Quick tap \(hotkeyLabel) + Shift (within 5s of a paste)", "Refine the previous output — opens the action menu against the last paste, no new dictation")
                    row("Right-click menu bar icon", "Status, History, Settings, Quit")
                }

                section(title: "Modes — automatic") {
                    row("Nothing selected", "Dictation: speech is cleaned and pasted at the cursor")
                    row("Text selected", "Edit: speech becomes an instruction to rewrite the selection")
                    row("\"bullet list:\", \"email:\", etc.", "Command: formatted output")
                    row("\"insert <trigger>\"", "Snippet: pastes the expansion directly, no LLM")
                }

                section(title: "Action menu (Right Option + Shift)") {
                    row("Grammar", "Fix L2 / non-native errors, preserve voice")
                    row("Personal", "Casual / friendly conversational rewrite")
                    row("Formal", "Polished professional rewrite")
                    row("Shorter", "Concise rewrite, ~half length")
                    row("Bullets", "Convert to bulleted list, parallel structure")
                    row("Email", "Wrap in greeting + body + sign-off")
                    row("Summary", "2–3 sentence summary, key ideas only")
                    row("Esc", "Cancel — no paste")
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
