import AVFoundation
import Combine
import SwiftUI

struct PermissionsStep: View {
    let onContinue: () -> Void
    let onBack: () -> Void

    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var axTrusted = AccessibilityChecker.isTrusted
    @State private var pollTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var allGranted: Bool { micGranted && axTrusted }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Two permissions, one time")
                    .font(.title2.weight(.semibold))
                Text("Whisperly needs access to your microphone (to record) and Accessibility (to detect what you've selected and paste at the cursor).")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            permissionRow(
                title: "Microphone",
                detail: "Records your voice while you hold the hotkey. Audio is sent to Groq for transcription.",
                symbol: "mic.fill",
                granted: micGranted,
                action: requestMic,
                actionLabel: micGranted ? "Granted" : "Request access"
            )

            permissionRow(
                title: "Accessibility",
                detail: "Reads the text you've selected and posts ⌘V to paste your dictation. Whisperly never observes anything else.",
                symbol: "accessibility",
                granted: axTrusted,
                action: openAXSettings,
                actionLabel: axTrusted ? "Granted" : "Open System Settings…"
            )

            Spacer(minLength: 0)
            HStack {
                Button("Back") { onBack() }
                Spacer()
                Button("Continue") { onContinue() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!allGranted)
            }
        }
        .onReceive(pollTimer) { _ in
            // Poll AX trust because granting it requires switching to System
            // Settings — there's no callback when the user toggles it.
            let nowMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let nowAX = AccessibilityChecker.isTrusted
            if nowMic != micGranted { micGranted = nowMic }
            if nowAX != axTrusted { axTrusted = nowAX }
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        detail: String,
        symbol: String,
        granted: Bool,
        action: @escaping () -> Void,
        actionLabel: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(granted ? .green : .secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.headline)
                    if granted {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(actionLabel) { action() }
                .disabled(granted)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    private func requestMic() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run { micGranted = granted }
        }
    }

    private func openAXSettings() {
        _ = AccessibilityChecker.ensureTrusted(promptIfNeeded: true)
        AccessibilityChecker.openSystemSettings()
    }
}
