import Combine
import SwiftUI
import os

/// First-launch flow. UserDefaults flag `onboarding.completed` records that
/// the user finished the steps. The window auto-opens on first launch and
/// can be reopened later via Settings.
final class OnboardingState: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome = 0
        case permissions
        case apiKeys
        case hotkey
        case firstDictation

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .permissions: return "Permissions"
            case .apiKeys: return "API keys"
            case .hotkey: return "Hotkey"
            case .firstDictation: return "Try it"
            }
        }
    }

    @Published var step: Step = .welcome

    static let completedDefaultsKey = "onboarding.completed"

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedDefaultsKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedDefaultsKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: completedDefaultsKey)
    }

    func goNext() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    func goBack() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        step = prev
    }
}

struct OnboardingWindow: View {
    let groq: GroqClient
    let haiku: HaikuClient
    let keychain: KeychainService
    let appState: AppState
    let dismiss: () -> Void

    @StateObject private var onboarding = OnboardingState()

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
            Divider()
            currentStep
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
        }
        .frame(width: 620, height: 520)
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingState.Step.allCases) { step in
                let isActive = step == onboarding.step
                let isPast = step.rawValue < onboarding.step.rawValue
                Capsule()
                    .fill(isActive ? Color.accentColor : (isPast ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.2)))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var currentStep: some View {
        switch onboarding.step {
        case .welcome:
            WelcomeStep(onContinue: onboarding.goNext)
        case .permissions:
            PermissionsStep(onContinue: onboarding.goNext, onBack: onboarding.goBack)
        case .apiKeys:
            APIKeysStep(
                groq: groq,
                haiku: haiku,
                keychain: keychain,
                onContinue: onboarding.goNext,
                onBack: onboarding.goBack
            )
        case .hotkey:
            HotkeyStep(onContinue: onboarding.goNext, onBack: onboarding.goBack)
        case .firstDictation:
            FirstDictationStep(appState: appState, onFinish: {
                OnboardingState.markCompleted()
                dismiss()
            }, onBack: onboarding.goBack)
        }
    }
}
