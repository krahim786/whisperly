import SwiftUI

struct HotkeySettingsView: View {
    @ObservedObject private var config = HotkeyConfig.shared

    var body: some View {
        Form {
            Section("Activation") {
                Picker("Mode", selection: $config.mode) {
                    ForEach(HotkeyConfig.Mode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(modeHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Key") {
                Picker("Hotkey key", selection: $config.key) {
                    ForEach(HotkeyConfig.Key.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                Text("Modifier-only keys are used so the hotkey doesn't collide with regular typing. Right-side modifiers are recommended — most apps reserve left-side modifiers for shortcuts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 360)
    }

    private var modeHelp: String {
        switch config.mode {
        case .hold:
            return "Hold the key to record. Release to transcribe and paste."
        case .toggle:
            return "Tap the key twice quickly (within 0.4s) to start. Tap once more to stop."
        }
    }
}

#Preview {
    HotkeySettingsView()
}
