import AppKit
import Combine
import Foundation
import SwiftUI

/// Owns the HUD panel and its hosting view. Observes `AppState.phase` and
/// `HotkeyConfig.showHUD` to show/hide and reposition.
@MainActor
final class HUDController {
    private let appState: AppState
    private let config: HotkeyConfig
    private var panel: HUDPanel?
    private var hosting: NSHostingView<HUDView>?
    private var cancellables = Set<AnyCancellable>()

    private let panelSize = NSSize(width: 360, height: 80)
    private let edgeMargin: CGFloat = 24

    init(appState: AppState, config: HotkeyConfig) {
        self.appState = appState
        self.config = config
    }

    func start() {
        // React to phase changes for show/hide.
        appState.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self else { return }
                if phase == .idle {
                    self.hide()
                } else {
                    self.show()
                }
            }
            .store(in: &cancellables)

        // React to the showHUD toggle — if disabled mid-dictation, hide.
        config.$showHUD
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if !enabled { self.hide() }
                else if self.appState.phase != .idle { self.show() }
            }
            .store(in: &cancellables)

        // Reposition on screen reconfiguration so the HUD doesn't end up offscreen.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.repositionIfVisible() }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        hide()
    }

    // MARK: - Show / Hide

    /// Bring the panel onscreen. The actual fade-in is driven entirely by
    /// SwiftUI inside `HUDView` (via `.opacity` and `.blur` keyed on
    /// `appState.phase`); we just need the window to exist on the screen
    /// list so SwiftUI has somewhere to render to. The panel's `alphaValue`
    /// is held at 1 forever — no Core Animation on the AppKit side.
    ///
    /// History: an earlier design animated `panel.animator().alphaValue` in
    /// parallel with the SwiftUI blur. Two animation systems observing the
    /// same `phase` publisher had no shared clock. They mostly stayed in
    /// sync, but over enough rapid cycles the SwiftUI .blur @State could
    /// fall out of sync with the panel alpha — eventually leaving the HUD
    /// "invisible after a while of use." Collapsing both into one SwiftUI
    /// animation eliminates the race.
    private func show() {
        guard config.showHUD else { return }
        let panel = ensurePanel()
        positionPanel(panel)

        // Cancel any in-flight delayed orderOut so a quick re-press during
        // the disappear animation doesn't retire the panel out from under us.
        hideTask?.cancel()
        hideTask = nil

        // Force alpha to 1 — defensive against anything that may have left
        // it at 0 (older builds, future regressions). With this set the
        // panel content's visibility is purely a function of SwiftUI's
        // .opacity, which is keyed on appState.phase.
        panel.alphaValue = 1

        // orderFrontRegardless avoids activating the app, preserving the
        // user's frontmost text editor as key.
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// Schedule the panel to leave the screen list once SwiftUI's fade-out
    /// has visually completed. We don't animate alpha here — SwiftUI's
    /// `.opacity` keyed on `phase == .idle` does the visible work. We just
    /// wait the disappear duration plus a small buffer, then `orderOut`
    /// (and only if the phase is still .idle — a rapid re-press cancels).
    private func hide() {
        guard let panel = self.panel, panel.isVisible else { return }
        let panelRef = panel
        hideTask?.cancel()
        // Sleep a touch longer than the SwiftUI disappear animation so we
        // never orderOut mid-fade. 50 ms buffer is imperceptible.
        let waitNanos = HUDView.disappearNanoseconds + 50_000_000
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: waitNanos)
            guard !Task.isCancelled, let self else { return }
            // If a new dictation kicked off during the fade, phase is no
            // longer .idle and the user expects to see the HUD — keep it.
            guard self.appState.phase == .idle else { return }
            panelRef.orderOut(nil)
        }
        hideTask = task
    }

    private var hideTask: Task<Void, Never>?

    private func repositionIfVisible() {
        guard let panel, panel.isVisible else { return }
        positionPanel(panel)
    }

    // MARK: - Panel construction

    private func ensurePanel() -> HUDPanel {
        if let panel { return panel }
        let panel = HUDPanel(contentSize: panelSize)
        let hosting = NSHostingView(rootView: HUDView(appState: appState))
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        hosting.autoresizingMask = [.width, .height]
        // Hosting view background must be transparent so the panel's clear
        // background + the SwiftUI material can show through.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel
        return panel
    }

    private func positionPanel(_ panel: HUDPanel) {
        // Bottom-center of the screen with the keyboard focus, falling back
        // to the main screen. Centered horizontally, sat `edgeMargin` above
        // the bottom of the visible area (so it clears the Dock).
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let screen = targetScreen else { return }
        let frame = screen.visibleFrame
        let originX = frame.midX - panelSize.width / 2
        let originY = frame.minY + edgeMargin
        panel.setFrame(NSRect(x: originX, y: originY, width: panelSize.width, height: panelSize.height), display: true)
    }
}
