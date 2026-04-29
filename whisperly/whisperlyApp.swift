import SwiftUI
import os

@main
struct whisperlyApp: App {
    @StateObject private var appState: AppState
    @StateObject private var config = HotkeyConfig.shared
    @StateObject private var snippetStore: SnippetStore
    @StateObject private var dictionaryStore: DictionaryStore
    @StateObject private var analytics: AnalyticsTracker
    @StateObject private var updateService: UpdateService

    private let hotkey: HotkeyManager
    private let recorder: AudioRecorder
    private let groq: GroqClient
    private let haiku: HaikuClient
    private let context: ContextDetector
    private let inserter: TextInserter
    private let sound: SoundPlayer
    private let history: HistoryStore?
    private let hudController: HUDController
    private let keychain = KeychainService()

    private static let logger = Logger(subsystem: "com.karim.whisperly", category: "App")

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
        let snippets = SnippetStore()
        let dictionary = DictionaryStore()

        let history: HistoryStore?
        do {
            history = try HistoryStore()
        } catch {
            Self.logger.error("HistoryStore init failed; history disabled this session: \(error.localizedDescription, privacy: .public)")
            history = nil
        }

        self.hotkey = hotkey
        self.recorder = recorder
        self.groq = groq
        self.haiku = haiku
        self.context = context
        self.inserter = inserter
        self.sound = sound
        self.history = history

        let actionMenu = ActionMenuController()

        let state = AppState(
            hotkey: hotkey,
            recorder: recorder,
            groq: groq,
            haiku: haiku,
            context: context,
            inserter: inserter,
            sound: sound,
            history: history,
            snippets: snippets,
            dictionary: dictionary,
            config: config,
            actionMenu: actionMenu
        )
        self.hudController = HUDController(appState: state, config: config)

        let analytics = AnalyticsTracker(store: history)
        let updates = UpdateService()

        // When TextInserter sees a paste attempt with AX trust missing, it
        // skips the doomed ⌘V and signals AppState to refresh the banner +
        // surface the once-per-session alert. Captured weakly so the closure
        // doesn't keep AppState alive past app termination.
        inserter.onAccessibilityRevoked = { [weak state] in
            state?.presentAccessibilityRevokedAlertIfNeeded()
        }

        _appState = StateObject(wrappedValue: state)
        _snippetStore = StateObject(wrappedValue: snippets)
        _dictionaryStore = StateObject(wrappedValue: dictionary)
        _analytics = StateObject(wrappedValue: analytics)
        _updateService = StateObject(wrappedValue: updates)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                appState: appState,
                hudController: hudController,
                dictionaryStore: dictionaryStore,
                analytics: analytics,
                updates: updateService
            )
        } label: {
            Image(systemName: iconName(for: appState.phase))
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsRoot(
                historyStore: history,
                snippetStore: snippetStore,
                dictionaryStore: dictionaryStore,
                updates: updateService
            )
        }

        Window("Whisperly History", id: "history") {
            if let history {
                HistoryWindowView(store: history, inserter: inserter, dictionary: dictionaryStore)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text("History storage failed to open.")
                    Text("Check Console for details.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 360, height: 200)
            }
        }
        .windowResizability(.contentSize)

        Window("Whisperly Stats", id: "stats") {
            StatsWindowView(analytics: analytics)
        }
        .windowResizability(.contentSize)

        Window("Set up Whisperly", id: "onboarding") {
            OnboardingHost(
                groq: groq,
                haiku: haiku,
                keychain: keychain,
                appState: appState
            )
        }
        .windowResizability(.contentSize)

        Window("About Whisperly", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Window("Acknowledgements", id: "acknowledgements") {
            AcknowledgementsView()
        }
        .windowResizability(.contentSize)

        Window("Whisperly Help", id: "help") {
            HelpCheatSheetView()
        }
        .windowResizability(.contentSize)
        .commands {
            // Replace the default Help menu with our cheat sheet entry.
            CommandGroup(replacing: .help) {
                Button("Whisperly Help") {
                    NotificationCenter.default.post(name: .showHelpCheatSheet, object: nil)
                }
                .keyboardShortcut("?", modifiers: [.command])
                Divider()
                Button("Privacy") {
                    if let url = Bundle.main.url(forResource: "PRIVACY", withExtension: "md") {
                        NSWorkspace.shared.open(url)
                    } else if let url = URL(string: "https://github.com/anthropics/claude-code") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Acknowledgements") {
                    NotificationCenter.default.post(name: .showAcknowledgements, object: nil)
                }
            }
            // Replace the default About menu item to open our custom window,
            // and add "Check for Updates…" right beneath it (Apple HIG: this
            // is where users expect to find it).
            CommandGroup(replacing: .appInfo) {
                Button("About Whisperly") {
                    NotificationCenter.default.post(name: .showAbout, object: nil)
                }
                Button("Check for Updates…") {
                    updateService.checkForUpdates()
                }
                .disabled(!updateService.canCheckForUpdates)
            }
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

private struct OnboardingHost: View {
    let groq: GroqClient
    let haiku: HaikuClient
    let keychain: KeychainService
    let appState: AppState

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        OnboardingWindow(
            groq: groq,
            haiku: haiku,
            keychain: keychain,
            appState: appState,
            dismiss: { dismissWindow(id: "onboarding") }
        )
    }
}

private struct MenuBarContent: View {
    @ObservedObject var appState: AppState
    let hudController: HUDController
    @ObservedObject var dictionaryStore: DictionaryStore
    @ObservedObject var analytics: AnalyticsTracker
    @ObservedObject var updates: UpdateService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            // Accessibility-revoked banner. Surfaces silently-failing paste
            // mode that the ad-hoc-signed family-share build hits after every
            // Sparkle update. The text item is non-clickable; the button next
            // to it deep-links to System Settings → Accessibility.
            if !appState.isAccessibilityTrusted {
                Text("⚠ Accessibility permission needed")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                Button("Open Privacy & Security Settings") {
                    AccessibilityChecker.openSystemSettings()
                }
                Divider()
            }

            Text(statusText(appState.phase))
                .font(.caption)
                .foregroundStyle(.secondary)

            // Tiny analytics widget — surfaced inline so users see their habit
            // without opening a separate window. Always rendered (empty state
            // when no dictations yet) to avoid SwiftUI MenuBarExtra mis-indexing
            // its items when the row count changes.
            Text(analyticsTodayLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(analyticsAllTimeLine)
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Suggestion line is also always rendered; falls back to invisible
            // single-space when there are none, so the menu items stay stable.
            Text(suggestionLine)
                .font(.caption2)
                .foregroundStyle(dictionaryStore.pendingSuggestionCount > 0 ? .orange : .clear)

            Divider()
            Button("Show History…") {
                openWindow(id: "history")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("y", modifiers: [.command])
            Button("Show Stats…") {
                openWindow(id: "stats")
                NSApp.activate(ignoringOtherApps: true)
            }
            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(",", modifiers: [.command])
            Divider()
            Button("About Whisperly") {
                openWindow(id: "about")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Whisperly Help") {
                openWindow(id: "help")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("?", modifiers: [.command])
            Button("Check for Updates…") {
                updates.checkForUpdates()
            }
            .disabled(!updates.canCheckForUpdates)
            Divider()
            Button("Quit Whisperly") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
        .task {
            appState.bootstrap()
            hudController.start()
            _ = AccessibilityChecker.ensureTrusted(promptIfNeeded: true)
            analytics.refresh()

            // First-launch onboarding: open the flow if it's never been
            // completed. Defer slightly so the menu bar / settings are wired
            // before we open another window.
            if !OnboardingState.hasCompleted {
                try? await Task.sleep(nanoseconds: 250_000_000)
                openWindow(id: "onboarding")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reopenOnboarding)) { _ in
            openWindow(id: "onboarding")
            NSApp.activate(ignoringOtherApps: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAbout)) { _ in
            openWindow(id: "about")
            NSApp.activate(ignoringOtherApps: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAcknowledgements)) { _ in
            openWindow(id: "acknowledgements")
            NSApp.activate(ignoringOtherApps: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showHelpCheatSheet)) { _ in
            openWindow(id: "help")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var analyticsTodayLine: String {
        if analytics.summary.dictationsAllTime == 0 {
            return "No dictations yet — try the hotkey"
        }
        return "\(analytics.summary.wordsToday) words today · \(analytics.summary.streakDays)-day streak"
    }

    private var analyticsAllTimeLine: String {
        if analytics.summary.dictationsAllTime == 0 {
            return " "
        }
        return "All-time: \(analytics.summary.wordsAllTime) words · \(formatTime(analytics.summary.timeSavedMinutes)) saved"
    }

    private var suggestionLine: String {
        let count = dictionaryStore.pendingSuggestionCount
        if count == 0 { return " " }
        return "\(count) dictionary suggestion\(count == 1 ? "" : "s")"
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

    private func formatTime(_ minutes: Double) -> String {
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(Int(minutes))m" }
        let hours = Int(minutes / 60)
        let m = Int(minutes.truncatingRemainder(dividingBy: 60))
        return "\(hours)h \(m)m"
    }
}
