import AppKit
import Foundation
import SwiftUI
import os

/// Owns the action-menu panel. AppState calls `choose()` after transcription
/// when the user dictated with Right Option + Shift; the call suspends until
/// the user clicks a button (or cancels), then returns the chosen style.
///
/// The panel is positioned above the HUD's bottom-center spot. No timeout,
/// no auto-action — the user explicitly picks. A global Esc keyDown monitor
/// dismisses with `nil` for an escape hatch.
@MainActor
final class ActionMenuController {
    private let logger = Logger(subsystem: "com.karim.whisperly", category: "ActionMenu")

    private var panel: ActionMenuPanel?
    private var hosting: NSHostingView<ActionMenuView>?
    private var pendingContinuation: CheckedContinuation<ActionMenuStyle?, Never>?
    private var escMonitorLocal: Any?
    private var escMonitorGlobal: Any?

    // Two rows of buttons (4 + 3) — height = 2×56 button + 6 inter-row gap +
    // 8×2 panel padding + a little breathing room.
    private let menuSize = NSSize(width: 360, height: 144)
    private let hudHeight: CGFloat = 80
    private let hudBottomMargin: CGFloat = 24
    private let gapAboveHUD: CGFloat = 12

    /// Suspend until the user picks a style. Returns `nil` if the user
    /// pressed Esc or otherwise cancelled.
    func choose() async -> ActionMenuStyle? {
        // Defensively cancel any prior pending continuation before queuing
        // a new one — getting two of these in flight would deadlock.
        if let prior = pendingContinuation {
            pendingContinuation = nil
            prior.resume(returning: nil)
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<ActionMenuStyle?, Never>) in
            self.pendingContinuation = cont
            self.show()
        }
    }

    // MARK: - Show / hide

    private func show() {
        let panel = self.panel ?? ActionMenuPanel(contentSize: menuSize)
        self.panel = panel

        let hosting = NSHostingView(rootView: ActionMenuView { [weak self] style in
            self?.dismiss(with: style)
        })
        hosting.frame = NSRect(origin: .zero, size: menuSize)
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        self.hosting = hosting

        positionPanel(panel)
        panel.orderFrontRegardless()
        installEscapeMonitors()
    }

    private func positionPanel(_ panel: ActionMenuPanel) {
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let screen = targetScreen else { return }
        let frame = screen.visibleFrame
        let originX = frame.midX - menuSize.width / 2
        let originY = frame.minY + hudBottomMargin + hudHeight + gapAboveHUD
        panel.setFrame(
            NSRect(x: originX, y: originY, width: menuSize.width, height: menuSize.height),
            display: true
        )
    }

    private func dismiss(with choice: ActionMenuStyle?) {
        removeEscapeMonitors()
        panel?.orderOut(nil)
        let cont = pendingContinuation
        pendingContinuation = nil
        cont?.resume(returning: choice)
    }

    // MARK: - Esc to cancel

    private func installEscapeMonitors() {
        // Local monitor catches Esc when our (non-activating) panel is up
        // and the user happens to be focused in our app — rare but cheap.
        escMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.dismiss(with: nil)
                return nil
            }
            return event
        }
        // Global monitor catches Esc anywhere in the system — covers the
        // common case where the user's text editor is still frontmost.
        escMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in self?.dismiss(with: nil) }
            }
        }
    }

    private func removeEscapeMonitors() {
        if let m = escMonitorLocal { NSEvent.removeMonitor(m); escMonitorLocal = nil }
        if let m = escMonitorGlobal { NSEvent.removeMonitor(m); escMonitorGlobal = nil }
    }
}
