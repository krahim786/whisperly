import AppKit
import Combine
import Foundation
import os

/// Detects press and release of the Right Option key (keyCode 61) globally
/// and locally, and publishes typed events on `events`.
///
/// Modifier-only keys can't be captured by Carbon hotkey APIs — they're modifier
/// flag changes, not key events. We therefore monitor `.flagsChanged` via NSEvent
/// and inspect `keyCode` + `modifierFlags` to detect transitions.
///
/// We need both monitors:
/// - `addGlobalMonitorForEvents` fires when our app is *not* frontmost (the typical case).
/// - `addLocalMonitorForEvents` fires when our app *is* frontmost (e.g. settings window open).
@MainActor
final class HotkeyManager {
    enum HotkeyEvent {
        case pressed
        case released
    }

    // Default to Right Option. Day 2 will make this user-configurable.
    private let watchedKeyCode: UInt16 = 61
    // Modifier flag the watched key contributes when held.
    private let watchedFlag: NSEvent.ModifierFlags = .option

    private let logger = Logger(subsystem: "com.karim.whisperly", category: "HotkeyManager")
    private let subject = PassthroughSubject<HotkeyEvent, Never>()

    var events: AnyPublisher<HotkeyEvent, Never> { subject.eraseToAnyPublisher() }

    // Track previous press state so we only emit on transitions, not on every
    // flagsChanged tick (which fires for any modifier change in the system).
    private var isPressed = false
    private var pressTimestamp: Date?

    // Safety timer: if the user somehow never releases (e.g. a focus glitch),
    // force-release after this interval.
    private let maxHoldDuration: TimeInterval = 60
    private var maxHoldTask: Task<Void, Never>?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    init() {}

    deinit {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
    }

    func start() {
        guard globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Global monitor closure runs on the main thread, but Sendable rules
            // require us to hop explicitly to MainActor for safety in case Apple
            // changes that. Also lets us touch MainActor-isolated state.
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Local monitor returns the event so other observers still see it.
            self?.handleFlagsChanged(event)
            return event
        }

        logger.info("HotkeyManager started — watching keyCode \(self.watchedKeyCode, privacy: .public)")
    }

    func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
        if isPressed {
            isPressed = false
            subject.send(.released)
        }
        maxHoldTask?.cancel()
        maxHoldTask = nil
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        // Only react when the watched physical key changes state.
        guard event.keyCode == watchedKeyCode else { return }

        // Determine whether the watched modifier is currently set in the post-change flags.
        let isFlagSet = event.modifierFlags.contains(watchedFlag)

        // The watched key's keyCode changed and the matching flag is set → press.
        // The watched key's keyCode changed and the matching flag is clear → release.
        // (If the user is also holding the *other* option key, the flag may stay set
        //  on right-option release. We can't perfectly disambiguate left vs right
        //  option from modifierFlags alone, so we accept that limitation for Day 1
        //  and treat any flag-cleared transition as the canonical release.)
        if isFlagSet && !isPressed {
            isPressed = true
            pressTimestamp = Date()
            logger.debug("Right Option pressed (kc=\(event.keyCode, privacy: .public), flags=\(event.modifierFlags.rawValue, privacy: .public))")
            subject.send(.pressed)
            scheduleMaxHoldGuard()
        } else if !isFlagSet && isPressed {
            isPressed = false
            let held = pressTimestamp.map { Date().timeIntervalSince($0) } ?? 0
            pressTimestamp = nil
            logger.debug("Right Option released after \(String(format: "%.3f", held))s (kc=\(event.keyCode, privacy: .public))")
            subject.send(.released)
            maxHoldTask?.cancel()
            maxHoldTask = nil
        } else {
            // Same-state event (e.g. another modifier toggled while option is held).
            // Ignore.
        }
    }

    private func scheduleMaxHoldGuard() {
        maxHoldTask?.cancel()
        let limit = maxHoldDuration
        maxHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard let self, self.isPressed, !Task.isCancelled else { return }
            self.logger.warning("Max hold duration exceeded — force-releasing.")
            self.isPressed = false
            self.pressTimestamp = nil
            self.subject.send(.released)
        }
    }
}
