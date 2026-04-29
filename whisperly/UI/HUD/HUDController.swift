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

    private func show() {
        guard config.showHUD else { return }
        let panel = ensurePanel()
        positionPanel(panel)
        // orderFrontRegardless avoids activating the app — this is critical so
        // we don't pull focus away from the user's text editor mid-dictation.
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

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
