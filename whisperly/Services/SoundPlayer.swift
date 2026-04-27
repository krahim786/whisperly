import AppKit
import Foundation

/// Plays the standard macOS system chimes for start/stop feedback.
/// Toggles read live from `HotkeyConfig` so changes apply immediately.
@MainActor
final class SoundPlayer {
    private let config: HotkeyConfig

    // Pre-resolved NSSound instances. NSSound is cached per name by AppKit;
    // holding the instance is mostly a hint that we want to play synchronously.
    private let startSound = NSSound(named: NSSound.Name("Tink"))
    private let stopSound = NSSound(named: NSSound.Name("Pop"))

    init(config: HotkeyConfig) {
        self.config = config
    }

    func playStart() {
        guard config.playStartSound else { return }
        startSound?.stop()
        startSound?.play()
    }

    func playStop() {
        guard config.playStopSound else { return }
        stopSound?.stop()
        stopSound?.play()
    }
}
