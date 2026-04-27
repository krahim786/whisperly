import AppKit
import ApplicationServices
import Foundation
import os

/// Thin wrapper for Accessibility-permission checks. We need AX trust both for
/// posting the synthesized ⌘V keystroke that pastes our cleaned text and for
/// reading the focused element's `kAXSelectedTextAttribute` to detect edit-mode.
@MainActor
enum AccessibilityChecker {
    private static let logger = Logger(subsystem: "com.karim.whisperly", category: "Accessibility")

    /// True if the app is in System Settings → Privacy & Security → Accessibility.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system "would like to control your computer using accessibility
    /// features" dialog the first time it's needed. Subsequent calls just return
    /// the current trust state — they don't re-prompt unless the user has
    /// already revoked permission in Settings.
    @discardableResult
    static func ensureTrusted(promptIfNeeded: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [key: promptIfNeeded] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            logger.info("Accessibility not yet granted (prompt=\(promptIfNeeded, privacy: .public))")
        }
        return trusted
    }

    /// Open System Settings directly to the Accessibility pane. Lets us put a
    /// "Open Settings" button next to "Whisperly needs Accessibility" UI.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
