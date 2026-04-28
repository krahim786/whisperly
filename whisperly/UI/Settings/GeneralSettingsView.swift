import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject private var config = HotkeyConfig.shared
    @ObservedObject var updates: UpdateService
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

            Section("Translation") {
                Toggle("Translate dictation", isOn: $config.translationEnabled)
                if config.translationEnabled {
                    Picker("Speaking language", selection: $config.translationInputLanguage) {
                        ForEach(Language.inputOptions) { lang in
                            Text(lang.pickerLabel).tag(lang)
                        }
                    }
                    Picker("Translate to", selection: $config.translationOutputLanguage) {
                        ForEach(Language.outputOptions) { lang in
                            Text(lang.pickerLabel).tag(lang)
                        }
                    }
                }
                Text("Speak in any supported language and Whisperly will paste the translation. Pick \"Auto-detect\" as your speaking language if you switch between languages day to day. Snippets and command verbs are paused while translation is on, since both rely on English-language matching.")
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

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $updates.automaticChecks)
                HStack {
                    Button("Check now") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                    if let last = updates.lastCheckDateText {
                        Text("Last check: \(last)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never checked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if !updates.isFeedConfigured {
                    Text("⚠ The update feed URL is still a placeholder. See SPARKLE.md to wire up your appcast and EdDSA keypair before updates can flow.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Whisperly checks for new versions in the background and notifies you when one is available. Updates are EdDSA-signed end-to-end so only the maintainer's builds will install.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
    GeneralSettingsView(updates: UpdateService())
}
