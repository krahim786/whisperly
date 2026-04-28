import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject private var config = HotkeyConfig.shared
    @State private var launchAtLogin = LaunchAtLoginService.isEnabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Whisperly at login", isOn: launchAtLoginBinding)
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Whisperly stays in your menu bar — no Dock icon, no main window. Login launch keeps it ready when you sign in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            Section("Writing assistance") {
                Picker("Cleanup style", selection: $config.writingAssistance) {
                    ForEach(HotkeyConfig.WritingAssistance.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(config.writingAssistance.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Tip: even with Standard cleanup selected, you can ask for a one-off grammar fix by starting your dictation with \"fix grammar\" — for example \"fix grammar: he go to store yesterday\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Onboarding") {
                Button("Re-run onboarding") {
                    OnboardingState.reset()
                    NotificationCenter.default.post(name: .reopenOnboarding, object: nil)
                }
                Text("Walk through welcome, permissions, API keys, hotkey, and a guided first dictation again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Diagnostics") {
                Toggle("Write verbose logs to ~/Library/Logs/Whisperly/", isOn: $config.verboseLogging)
                HStack {
                    Button("Reveal log folder in Finder") {
                        if let folder = FileLogger.shared.logFolderURL {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                    }
                    .disabled(FileLogger.shared.logFolderURL == nil)
                    Spacer()
                }
                Text("Verbose logs include hotkey events, mode resolution, network results, and cache hit counts. Useful for filing issues — sensitive contents (API keys, transcripts) are never written.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 460)
        .onAppear {
            launchAtLogin = LaunchAtLoginService.isEnabled
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                do {
                    let actual = try LaunchAtLoginService.setEnabled(newValue)
                    launchAtLogin = actual
                    launchAtLoginError = nil
                } catch {
                    launchAtLoginError = error.localizedDescription
                    // Re-read so the toggle reflects reality.
                    launchAtLogin = LaunchAtLoginService.isEnabled
                }
            }
        )
    }
}

extension Notification.Name {
    static let reopenOnboarding = Notification.Name("com.karim.whisperly.reopenOnboarding")
}

#Preview {
    GeneralSettingsView()
}
