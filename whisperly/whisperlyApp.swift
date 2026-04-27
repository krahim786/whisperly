import SwiftUI
import os

@main
struct whisperlyApp: App {
    @StateObject private var appState: AppState
    @StateObject private var config = HotkeyConfig.shared

    private let hotkey: HotkeyManager
    private let recorder: AudioRecorder
    private let groq: GroqClient
    private let haiku: HaikuClient
    private let context: ContextDetector
    private let inserter: TextInserter
    private let sound: SoundPlayer
    private let hudController: HUDController

    private let logger = Logger(subsystem: "com.karim.whisperly", category: "App")

    init() {
        let keychain = KeychainService()
        let config = HotkeyConfig.shared
        let hotkey = HotkeyManager(config: config)
        let recorder = AudioRecorder()
        let groq = GroqClient(keychain: keychain)
        let haiku = HaikuClient(keychain: keychain)
        let context = ContextDetector()
        let inserter = TextInserter()
        let sound = SoundPlayer(config: config)

        self.hotkey = hotkey
        self.recorder = recorder
        self.groq = groq
        self.haiku = haiku
        self.context = context
        self.inserter = inserter
        self.sound = sound

        let state = AppState(
            hotkey: hotkey,
            recorder: recorder,
            groq: groq,
            haiku: haiku,
            context: context,
            inserter: inserter,
            sound: sound
        )
        self.hudController = HUDController(appState: state, config: config)
        _appState = StateObject(wrappedValue: state)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(appState: appState, hudController: hudController)
        } label: {
            Image(systemName: iconName(for: appState.phase))
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsRoot()
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
    let hudController: HUDController

    var body: some View {
        Group {
            Text(statusText(appState.phase))
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
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
            // Bootstrap once on first appearance: start the hotkey monitor and HUD.
            appState.bootstrap()
            hudController.start()
        }
    }

    private func statusText(_ phase: AppState.Phase) -> String {
        switch phase {
        case .idle: return "Whisperly — ready"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .cleaning: return "Polishing…"
        case .pasting: return "Pasting…"
        case .error(let message): return "Error: \(message)"
        }
    }
}
