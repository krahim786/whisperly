import AppKit
import ApplicationServices
import Foundation
import os

/// Resolves runtime context that affects how we format dictation:
///   - the frontmost app's user-facing name (for prompt context)
///   - whether the user has text selected in the focused element (mode = .edit)
@MainActor
final class ContextDetector {
    private let logger = Logger(subsystem: "com.karim.whisperly", category: "ContextDetector")

    private let systemWide: AXUIElement = AXUIElementCreateSystemWide()

    init() {
        // Bound every AX call so a hung target app can't lock us up at hotkey
        // press time. 0.25s is generous; legit calls return in single-digit ms.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
    }

    func frontmostAppName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
    }

    /// Synchronous best-effort read of the selected text in the focused UI
    /// element via Accessibility. Returns nil on:
    /// - no Accessibility permission (caller can prompt separately)
    /// - no focused element (e.g. nothing in foreground accepts text)
    /// - the focused element doesn't expose `kAXSelectedTextAttribute`
    ///   (Electron apps — Slack, Discord, Cursor, VS Code — typically fall here)
    /// - empty selection
    ///
    /// Never throws and never blocks beyond the AX timeout configured in init.
    func getSelectedText() -> String? {
        guard AccessibilityChecker.isTrusted else {
            logger.debug("getSelectedText: Accessibility not trusted; skipping.")
            return nil
        }

        var focusedElement: AnyObject?
        let focusError = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard focusError == .success, let focusedAX = focusedElement else {
            if focusError != .success {
                logger.debug("getSelectedText: focused element copy failed (\(focusError.rawValue, privacy: .public))")
            }
            return nil
        }

        // Force-cast is safe: kAXFocusedUIElementAttribute always returns AXUIElement on success.
        let element = focusedAX as! AXUIElement

        var selectedValue: AnyObject?
        let selectionError = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )
        guard selectionError == .success else {
            // Common case for Electron apps and many web inputs — no error spam needed.
            logger.debug("getSelectedText: kAXSelectedTextAttribute unavailable (\(selectionError.rawValue, privacy: .public))")
            return nil
        }

        guard let text = selectedValue as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }
}
