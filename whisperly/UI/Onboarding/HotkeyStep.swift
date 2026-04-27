import SwiftUI

struct HotkeyStep: View {
    let onContinue: () -> Void
    let onBack: () -> Void

    @ObservedObject private var config = HotkeyConfig.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pick your hotkey")
                    .font(.title2.weight(.semibold))
                Text("Whisperly listens while you hold (or toggle) a modifier key. Right-side modifiers are recommended — most apps don't reserve them for shortcuts.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Activation")
                    .font(.subheadline.weight(.medium))
                Picker("Activation", selection: $config.mode) {
                    ForEach(HotkeyConfig.Mode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(modeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))

            VStack(alignment: .leading, spacing: 12) {
                Text("Key")
                    .font(.subheadline.weight(.medium))
                Picker("Key", selection: $config.key) {
                    ForEach(HotkeyConfig.Key.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .labelsHidden()
                Text("You can change this any time from Settings → Hotkey.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))

            Spacer(minLength: 0)
            HStack {
                Button("Back") { onBack() }
                Spacer()
                Button("Continue") { onContinue() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    private var modeDescription: String {
        switch config.mode {
        case .hold: return "Press and hold to record. Release to transcribe and paste."
        case .toggle: return "Tap twice quickly to start, tap once to stop."
        }
    }
}
