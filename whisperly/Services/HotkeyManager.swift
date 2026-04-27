import AppKit
import Combine
import Foundation
import os

/// Detects press and release of a configurable modifier key (default Right
/// Option, keyCode 61) globally and locally, and publishes typed events.
///
/// Modifier-only keys can't be captured by Carbon hotkey APIs — they're
/// modifier flag changes, not key events. We monitor `.flagsChanged` and
/// inspect `keyCode` + `modifierFlags` to detect press/release transitions.
///
/// Two activation modes (configured via `HotkeyConfig`):
/// - `.hold` — emit `.pressed` on key down, `.released` on key up.
/// - `.toggle` — two presses within 400ms emit `.pressed`; the next press
///   emits `.released`. Releases between presses are ignored.
///
/// We need both monitors because:
/// - `addGlobalMonitorForEvents` fires when our app is *not* frontmost.
/// - `addLocalMonitorForEvents` fires when our app *is* frontmost.
@MainActor
final class HotkeyManager {
    enum HotkeyEvent {
        case pressed
        case released
    }

    private let logger = Logger(subsystem: "com.karim.whisperly", category: "HotkeyManager")
    private let subject = PassthroughSubject<HotkeyEvent, Never>()
    private let config: HotkeyConfig
    private var configCancellables = Set<AnyCancellable>()

    var events: AnyPublisher<HotkeyEvent, Never> { subject.eraseToAnyPublisher() }

    // Hold-mode state.
    private var isHoldPressed = false
    private var holdPressTimestamp: Date?

    // Toggle-mode state.
    private var isToggleActive = false
    private var lastTapTimestamp: Date?
    private let doubleTapWindow: TimeInterval = 0.4

    // Safety: force-release after this duration in hold mode.
    private let maxHoldDuration: TimeInterval = 60
    private var maxHoldTask: Task<Void, Never>?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(config: HotkeyConfig) {
        self.config = config
    }

    deinit {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
    }

    func start() {
        guard globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Hop to MainActor so we can touch isolated state safely.
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        // If the user changes the mode while recording is in progress, reset state
        // so we don't end up stranded in toggle-active or hold-pressed.
        config.$mode
            .dropFirst()
            .sink { [weak self] _ in self?.resetState() }
            .store(in: &configCancellables)

        config.$key
            .dropFirst()
            .sink { [weak self] _ in self?.resetState() }
            .store(in: &configCancellables)

        logger.info("HotkeyManager started — key=\(self.config.key.displayName, privacy: .public) mode=\(self.config.mode.rawValue, privacy: .public)")
    }

    func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
        configCancellables.removeAll()
        resetState()
    }

    private func resetState() {
        if isHoldPressed {
            subject.send(.released)
        }
        if isToggleActive {
            subject.send(.released)
        }
        isHoldPressed = false
        isToggleActive = false
        holdPressTimestamp = nil
        lastTapTimestamp = nil
        maxHoldTask?.cancel()
        maxHoldTask = nil
    }

    // MARK: - Event handling

    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == config.key.keyCode else { return }

        let flag = config.key.modifierFlag
        let isFlagSet = event.modifierFlags.contains(flag)

        switch config.mode {
        case .hold:
            handleHoldMode(isFlagSet: isFlagSet, keyCode: event.keyCode)
        case .toggle:
            handleToggleMode(isFlagSet: isFlagSet)
        }
    }

    private func handleHoldMode(isFlagSet: Bool, keyCode: UInt16) {
        if isFlagSet && !isHoldPressed {
            isHoldPressed = true
            holdPressTimestamp = Date()
            logger.debug("Press (hold) kc=\(keyCode, privacy: .public)")
            subject.send(.pressed)
            scheduleMaxHoldGuard()
        } else if !isFlagSet && isHoldPressed {
            isHoldPressed = false
            let held = holdPressTimestamp.map { Date().timeIntervalSince($0) } ?? 0
            holdPressTimestamp = nil
            logger.debug("Release (hold) after \(String(format: "%.3f", held))s")
            subject.send(.released)
            maxHoldTask?.cancel()
            maxHoldTask = nil
        }
    }

    private func handleToggleMode(isFlagSet: Bool) {
        // We only act on key-down (flag-set) transitions in toggle mode.
        // Releases are silently consumed to avoid double-firing.
        guard isFlagSet else { return }

        let now = Date()

        if isToggleActive {
            // Any press while active stops the recording.
            isToggleActive = false
            lastTapTimestamp = nil
            logger.debug("Toggle stop")
            subject.send(.released)
            return
        }

        // Not active: check if this is the second tap of a double-tap.
        if let last = lastTapTimestamp, now.timeIntervalSince(last) <= doubleTapWindow {
            isToggleActive = true
            lastTapTimestamp = nil
            logger.debug("Toggle start (double-tap)")
            subject.send(.pressed)
        } else {
            // First tap. Wait for a possible second tap.
            lastTapTimestamp = now
            // Clear the "first tap" flag if no second tap arrives.
            Task { @MainActor [weak self, doubleTapWindow] in
                try? await Task.sleep(nanoseconds: UInt64(doubleTapWindow * 1_000_000_000) + 50_000_000)
                guard let self else { return }
                if let last = self.lastTapTimestamp, last == now {
                    self.lastTapTimestamp = nil
                }
            }
        }
    }

    private func scheduleMaxHoldGuard() {
        maxHoldTask?.cancel()
        let limit = maxHoldDuration
        maxHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard let self, self.isHoldPressed, !Task.isCancelled else { return }
            self.logger.warning("Max hold duration exceeded — force-releasing.")
            self.isHoldPressed = false
            self.holdPressTimestamp = nil
            self.subject.send(.released)
        }
    }
}
