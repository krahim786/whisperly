import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject private var config = HotkeyConfig.shared

    var body: some View {
        Form {
            Section("Visual feedback") {
                Toggle("Show recording HUD", isOn: $config.showHUD)
                Text("A small floating indicator that appears when you're dictating. It doesn't take focus, so paste continues to work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Audio feedback") {
                Toggle("Play start chime when recording begins", isOn: $config.playStartSound)
                Toggle("Play stop chime when recording ends", isOn: $config.playStopSound)
                Text("Subtle system sounds let you confirm the mic is live without looking at the HUD.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 360)
    }
}

#Preview {
    GeneralSettingsView()
}
