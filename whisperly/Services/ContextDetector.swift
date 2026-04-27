import AppKit
import ApplicationServices
import Carbon.HIToolbox
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

    /// Fallback selection capture for apps that don't expose
    /// `kAXSelectedTextAttribute` — typically Electron (Slack, Discord, Cursor,
    /// VS Code) and many web inputs. Synthesizes ⌘C, waits briefly for the
    /// pasteboard to update, reads it, and restores the previous pasteboard
    /// contents. Returns the captured text or nil if nothing was selected.
    ///
    /// Runs asynchronously so AppState can fire it in parallel with mic
    /// startup at hotkey press — by the time the user releases, the result
    /// is available and we can route to edit mode if it succeeded.
    func getSelectedTextViaCopy() async -> String? {
        let pasteboard = NSPasteboard.general
        let savedItems = snapshotPasteboard(pasteboard)
        let originalChangeCount = pasteboard.changeCount

        postCmdC()

        // Wait for the target app to handle the synthesized ⌘C. 80 ms is
        // generous; most apps settle in under 30 ms but Electron is slow.
        try? await Task.sleep(nanoseconds: 80_000_000)

        var captured: String?
        if pasteboard.changeCount != originalChangeCount,
           let raw = pasteboard.string(forType: .string),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            captured = raw
        }

        // Always restore so the user's clipboard isn't disturbed.
        pasteboard.clearContents()
        if let savedItems, !savedItems.isEmpty {
            pasteboard.writeObjects(savedItems)
        }

        if captured != nil {
            logger.debug("Cmd+C fallback captured \(captured?.count ?? 0, privacy: .public) chars")
        } else {
            logger.debug("Cmd+C fallback returned no selection (changeCount unchanged or empty).")
        }
        return captured
    }

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        guard let items = pasteboard.pasteboardItems else { return nil }
        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func postCmdC() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }
}
