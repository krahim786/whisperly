import SwiftUI
import os

@main
struct whisperlyApp: App {
    @StateObject private var appState: AppState

    private let hotkey: HotkeyManager
    private let recorder: AudioRecorder
    private let groq: GroqClient
    private let haiku: HaikuClient
    private let context: ContextDetector
    private let inserter: TextInserter
    private let keychain = KeychainService()

    private let logger = Logger(subsystem: "com.karim.whisperly", category: "App")

    init() {
        let keychain = KeychainService()
        let hotkey = HotkeyManager()
        let recorder = AudioRecorder()
        let groq = GroqClient(keychain: keychain)
        let haiku = HaikuClient(keychain: keychain)
        let context = ContextDetector()
        let inserter = TextInserter()

        self.hotkey = hotkey
        self.recorder = recorder
        self.groq = groq
        self.haiku = haiku
        self.context = context
        self.inserter = inserter

        let state = AppState(
            hotkey: hotkey,
            recorder: recorder,
            groq: groq,
            haiku: haiku,
            context: context,
            inserter: inserter
        )
        _appState = StateObject(wrappedValue: state)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(appState: appState)
        } label: {
            Image(systemName: iconName(for: appState.phase))
        }
        .menuBarExtraStyle(.menu)

        Settings {
            APIKeysSettingsView()
        }
    }

    private func iconName(for phase: AppState.Phase) -> String {
        switch phase {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .transcribing, .cleaning: return "waveform"
        case .pasting: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Group {
            Text(statusText(appState.phase))
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            // SettingsLink wires up the same Cmd+, opening as the standard Settings menu item.
            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(",", modifiers: [.command])
            Divider()
            Button("Quit Whisperly") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
        .task {
            // Bootstrap once when the menu first appears. SwiftUI calls .task
            // for the visible content; this is the simplest safe place to start
            // the global hotkey monitor for v1.
            appState.bootstrap()
        }
    }

    private func statusText(_ phase: AppState.Phase) -> String {
        switch phase {
        case .idle: return "Whisperly — hold Right Option to dictate"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .cleaning: return "Polishing…"
        case .pasting: return "Pasting…"
        case .error(let message): return "Error: \(message)"
        }
    }
}
