import SwiftUI

struct APIKeysStep: View {
    let groq: GroqClient
    let haiku: HaikuClient
    let keychain: KeychainService
    let onContinue: () -> Void
    let onBack: () -> Void

    enum ValidationState: Equatable {
        case idle
        case validating
        case ok
        case failure(String)
    }

    @State private var groqKey: String = ""
    @State private var anthropicKey: String = ""
    @State private var groqState: ValidationState = .idle
    @State private var anthropicState: ValidationState = .idle

    private var canContinue: Bool {
        groqState == .ok && anthropicState == .ok
    }

    var body: some View {
        if BundledKeys.hasAnyBundled {
            bundledKeysBody
        } else {
            standardBody
        }
    }

    private var bundledKeysBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("APIs are pre-configured")
                    .font(.title2.weight(.semibold))
                Text("This build of Whisperly ships with API keys baked in. You don't need to do anything here — dictation will use those keys.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Groq + Anthropic ready").font(.headline)
                    Text("If you'd rather use your own keys later, paste them in Settings → API Keys.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
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

    private var standardBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect your APIs")
                    .font(.title2.weight(.semibold))
                Text("Whisperly uses Groq Whisper for speech-to-text and Claude Haiku for cleanup. Keys are stored in your macOS Keychain.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            keyField(
                label: "Groq API key",
                helperLink: ("Get a Groq key →", "https://console.groq.com/keys"),
                text: $groqKey,
                state: groqState
            )

            keyField(
                label: "Anthropic API key",
                helperLink: ("Get an Anthropic key →", "https://console.anthropic.com/settings/keys"),
                text: $anthropicKey,
                state: anthropicState
            )

            Spacer(minLength: 0)
            HStack {
                Button("Back") { onBack() }
                Spacer()
                if isValidating {
                    ProgressView().controlSize(.small).padding(.trailing, 4)
                }
                Button("Validate keys") { validate() }
                    .disabled(groqKey.isEmpty || anthropicKey.isEmpty || isValidating)
                Button("Continue") { saveAndContinue() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!canContinue)
            }
        }
        .onAppear {
            groqKey = keychain.load(key: KeychainService.groqAPIKey) ?? ""
            anthropicKey = keychain.load(key: KeychainService.anthropicAPIKey) ?? ""
        }
    }

    private var isValidating: Bool {
        groqState == .validating || anthropicState == .validating
    }

    private func keyField(
        label: String,
        helperLink: (String, String),
        text: Binding<String>,
        state: ValidationState
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline.weight(.medium))
                Spacer()
                statusBadge(state)
            }
            SecureField("Paste your key", text: text)
                .textFieldStyle(.roundedBorder)
            HStack {
                Link(helperLink.0, destination: URL(string: helperLink.1)!)
                    .font(.caption)
                Spacer()
                if case let .failure(message) = state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ state: ValidationState) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .validating:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("checking…").font(.caption2).foregroundStyle(.secondary)
            }
        case .ok:
            Label("valid", systemImage: "checkmark.seal.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .foregroundStyle(.green)
        case .failure:
            Label("rejected", systemImage: "xmark.octagon.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    private func validate() {
        let g = groqKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        groqState = .validating
        anthropicState = .validating
        Task {
            // Run validations in parallel.
            async let groqResult = validateGroq(g)
            async let anthropicResult = validateAnthropic(a)
            let gOk = await groqResult
            let aOk = await anthropicResult
            await MainActor.run {
                groqState = gOk
                anthropicState = aOk
            }
        }
    }

    private func validateGroq(_ key: String) async -> ValidationState {
        do {
            _ = try await groq.validate(apiKey: key)
            return .ok
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func validateAnthropic(_ key: String) async -> ValidationState {
        do {
            _ = try await haiku.validate(apiKey: key)
            return .ok
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func saveAndContinue() {
        let g = groqKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        keychain.save(key: KeychainService.groqAPIKey, value: g)
        keychain.save(key: KeychainService.anthropicAPIKey, value: a)
        onContinue()
    }
}
