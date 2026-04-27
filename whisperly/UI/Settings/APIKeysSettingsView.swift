import SwiftUI

struct APIKeysSettingsView: View {
    @State private var groqKey: String = ""
    @State private var anthropicKey: String = ""
    @State private var savedFlash: Bool = false
    @State private var saveFlashTask: Task<Void, Never>?

    private let keychain = KeychainService()

    var body: some View {
        Form {
            Section("Groq (Whisper)") {
                SecureField("API key", text: $groqKey)
                    .textFieldStyle(.roundedBorder)
                Link("Get a Groq API key →", destination: URL(string: "https://console.groq.com/keys")!)
                    .font(.caption)
            }

            Section("Anthropic (Claude Haiku)") {
                SecureField("API key", text: $anthropicKey)
                    .textFieldStyle(.roundedBorder)
                Link("Get an Anthropic API key →", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.caption)
            }

            Section {
                HStack {
                    Button("Save", action: save)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(groqKey.isEmpty && anthropicKey.isEmpty)
                    if savedFlash {
                        Text("Saved")
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 360)
        .navigationTitle("API Keys")
        .onAppear(perform: load)
    }

    private func load() {
        groqKey = keychain.load(key: KeychainService.groqAPIKey) ?? ""
        anthropicKey = keychain.load(key: KeychainService.anthropicAPIKey) ?? ""
    }

    private func save() {
        let trimmedGroq = groqKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAnthropic = anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGroq.isEmpty {
            keychain.save(key: KeychainService.groqAPIKey, value: trimmedGroq)
        }
        if !trimmedAnthropic.isEmpty {
            keychain.save(key: KeychainService.anthropicAPIKey, value: trimmedAnthropic)
        }
        withAnimation { savedFlash = true }
        saveFlashTask?.cancel()
        saveFlashTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled {
                withAnimation { savedFlash = false }
            }
        }
    }
}

#Preview {
    APIKeysSettingsView()
}
