import AppKit
import Foundation

/// Borderless, non-activating floating panel for the dictation HUD.
///
/// The crucial properties:
/// - `.nonactivatingPanel` style — clicks/showing don't steal focus from the
///   frontmost app, which is the app we'll be pasting into.
/// - `.canJoinAllSpaces` collection behavior — visible when the user is in any
///   Space, including full-screen apps.
/// - `ignoresMouseEvents = true` — pointer events pass through to whatever's
///   below the HUD; the HUD is read-only.
/// - `level = .statusBar` — sits above ordinary windows but below alerts.
///
/// If any of these is wrong, paste either fails (HUD stole focus) or the HUD
/// vanishes when the user is in a fullscreen app.
@MainActor
final class HUDPanel: NSPanel {
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
        self.hasShadow = false
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
        self.ignoresMouseEvents = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.level = .statusBar
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
    }

    // Override so a non-activating panel never accepts key/main status —
    // this keeps the user's text-editor window primary the entire dictation.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
