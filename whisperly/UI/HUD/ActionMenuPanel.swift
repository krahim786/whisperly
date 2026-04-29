import AppKit
import Foundation

/// Borderless, non-activating panel for the post-dictation action menu.
///
/// Same focus-preservation invariants as HUDPanel — Whisperly never becomes
/// the key/main app, which means clicking a menu button doesn't steal focus
/// from the user's text editor. The follow-up paste lands in the same target
/// app the user was in when they triggered dictation.
///
/// Difference from HUDPanel: this one accepts mouse events (the buttons need
/// to be clickable). HUDPanel sets `ignoresMouseEvents = true` because it's
/// a read-only meter; this panel is interactive but still non-activating.
@MainActor
final class ActionMenuPanel: NSPanel {
    init(contentSize: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        self.hasShadow = true
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
        self.ignoresMouseEvents = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.level = .statusBar
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
