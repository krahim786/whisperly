import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import os

/// Pastes text into the frontmost app at the cursor by:
/// 1. Saving the existing pasteboard items (deep copy).
/// 2. Writing `text` as a plain string.
/// 3. Synthesizing Cmd+V via CGEvent at the HID event tap.
/// 4. Restoring the saved pasteboard contents 200ms later.
///
/// Requires Accessibility permission (granted via System Settings → Privacy → Accessibility)
/// for CGEvent posting to actually deliver keystrokes to other apps.
@MainActor
final class TextInserter {
    private let logger = Logger(subsystem: "com.karim.whisperly", category: "TextInserter")

    /// Called when a paste is attempted while Accessibility trust is missing.
    /// AppState wires this up to refresh its `isAccessibilityTrusted` flag and
    /// (if still revoked) show the one-shot NSAlert with an Open-Settings
    /// button. We skip the actual ⌘V in that case — posting it would be a
    /// silent no-op and the user wouldn't know why nothing happened.
    var onAccessibilityRevoked: (@MainActor () -> Void)?

    /// Symmetric alias for use sites that semantically replace a selection.
    /// The actual mechanism is identical: writing to the pasteboard and
    /// posting ⌘V — when text is currently selected, the paste replaces it.
    func replaceSelection(with text: String) async {
        await paste(text)
    }

    /// Replace whatever Whisperly pasted last by posting ⌘Z to undo the
    /// previous paste in the target app, then pasting `text` in its place.
    /// Used by the quick-refine flow: tap Right Option + Shift within 5s of
    /// a paste → action menu → pick a style → this method swaps the result.
    ///
    /// Caveat: macOS apps' undo stacks aren't a stable contract. If the user
    /// typed *anything* in the target app between the prior paste and this
    /// call, ⌘Z undoes that typing first, not our paste. The 5s refine
    /// window mitigates in practice; users rarely type within that window.
    /// The alternative — selecting the previous range and replacing — would
    /// need an AX read of cursor/selection ranges per app, which Electron
    /// breaks. ⌘Z + paste is the pragmatic v1.
    func replacePreviousPaste(with text: String) async {
        guard !text.isEmpty else { return }

        let trustedPrompt = AXIsProcessTrustedWithOptions(nil)
        if !trustedPrompt {
            onAccessibilityRevoked?()
            return
        }

        // Undo the previous paste in the target app's undo stack.
        postCmdZ()
        // Wait long enough for the target app to process the undo before
        // we start the replacement-paste — different apps have different
        // undo latencies, 80ms is generous but not perceptible.
        try? await Task.sleep(nanoseconds: 80_000_000)

        // Now paste the refined text via the existing paste path. The AX
        // check inside paste() is redundant after our check above, but
        // belt-and-braces is fine.
        await paste(text)
    }

    func paste(_ text: String) async {
        guard !text.isEmpty else { return }

        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        let trustedPrompt = AXIsProcessTrustedWithOptions(nil)
        logger.info("Pasting \(text.count, privacy: .public) chars into \(frontApp, privacy: .public) — Accessibility trusted: \(trustedPrompt, privacy: .public)")

        // Bail before touching the pasteboard if AX trust is missing — the
        // synthesized ⌘V will be silently dropped by the OS, and continuing
        // would leave the cleaned text on the user's clipboard for 230ms
        // before we restored the original. The callback lets AppState
        // refresh its banner flag and surface the one-shot alert.
        if !trustedPrompt {
            onAccessibilityRevoked?()
            return
        }

        let pasteboard = NSPasteboard.general
        let savedItems = snapshotPasteboard(pasteboard)
        let savedChangeCount = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let postChangeCount = pasteboard.changeCount

        // Brief delay before posting Cmd+V — gives the pasteboard time to settle
        // and gives the user's hotkey-key release a chance to be released by the OS,
        // so the synthesized Cmd modifier doesn't combine weirdly with held keys.
        try? await Task.sleep(nanoseconds: 30_000_000)

        postCmdV()

        // Wait long enough for the target app to consume the paste, then restore.
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Only restore if no other app/process clobbered the pasteboard since
        // we wrote to it. If they did, leave their content alone.
        if pasteboard.changeCount == postChangeCount {
            pasteboard.clearContents()
            if let savedItems, !savedItems.isEmpty {
                pasteboard.writeObjects(savedItems)
            }
        } else {
            logger.info("Pasteboard changed by another process (\(savedChangeCount) → \(pasteboard.changeCount)); skipping restore.")
        }
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

    private func postCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        // V key virtual keycode = 0x09
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }

    private func postCmdZ() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Z), keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Z), keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }
}
