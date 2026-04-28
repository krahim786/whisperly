import AppKit
import Combine
import Foundation

/// User-configurable hotkey settings. Persists to UserDefaults.
@MainActor
final class HotkeyConfig: ObservableObject {
    static let shared = HotkeyConfig()

    enum Mode: String, CaseIterable, Identifiable {
        case hold
        case toggle  // double-tap to start, single tap to stop

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .hold: return "Hold to talk"
            case .toggle: return "Double-tap to toggle"
            }
        }
    }

    /// How aggressively cleanup should rewrite. `.standard` is the original
    /// behavior — light grammar fixes, preserve voice. `.grammarFix` adds
    /// a stronger rewrite pass aimed at non-native English speakers or
    /// users whose dictation grammar is weak.
    enum WritingAssistance: String, CaseIterable, Identifiable {
        case standard
        case grammarFix

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .standard: return "Standard cleanup"
            case .grammarFix: return "Grammar correction"
            }
        }
        var caption: String {
            switch self {
            case .standard:
                return "Removes filler words and fixes obvious mistakes. Preserves your voice."
            case .grammarFix:
                return "Also fixes article use, verb tenses, prepositions, and awkward phrasing. Best for non-native speakers or casual speech that needs polishing."
            }
        }
    }

    /// Modifier-only keys we support. Modifier keys can't be reached via Carbon
    /// hotkey APIs — they only generate `.flagsChanged` events, which we
    /// monitor by `keyCode` in HotkeyManager.
    enum Key: Int, CaseIterable, Identifiable {
        case rightOption = 61
        case rightCommand = 54
        case rightShift = 60
        case rightControl = 62
        case fn = 63

        var id: Int { rawValue }
        var keyCode: UInt16 { UInt16(rawValue) }
        var displayName: String {
            switch self {
            case .rightOption: return "Right Option (⌥)"
            case .rightCommand: return "Right Command (⌘)"
            case .rightShift: return "Right Shift (⇧)"
            case .rightControl: return "Right Control (⌃)"
            case .fn: return "Fn"
            }
        }

        /// The modifier flag this key contributes when held. We use this to
        /// disambiguate press vs release in HotkeyManager.
        var modifierFlag: NSEvent.ModifierFlags {
            switch self {
            case .rightOption: return .option
            case .rightCommand: return .command
            case .rightShift: return .shift
            case .rightControl: return .control
            case .fn: return .function
            }
        }
    }

    private enum Defaults {
        static let mode = "hotkey.mode"
        static let key = "hotkey.key"
        static let playStartSound = "hotkey.playStartSound"
        static let playStopSound = "hotkey.playStopSound"
        static let showHUD = "hotkey.showHUD"
        static let historyEnabled = "history.enabled"
        static let historyRetentionDays = "history.retentionDays"
        static let verboseLogging = "logging.verbose"
        static let writingAssistance = "writing.assistance"
    }

    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Defaults.mode) }
    }

    @Published var key: Key {
        didSet { UserDefaults.standard.set(key.rawValue, forKey: Defaults.key) }
    }

    @Published var playStartSound: Bool {
        didSet { UserDefaults.standard.set(playStartSound, forKey: Defaults.playStartSound) }
    }

    @Published var playStopSound: Bool {
        didSet { UserDefaults.standard.set(playStopSound, forKey: Defaults.playStopSound) }
    }

    @Published var showHUD: Bool {
        didSet { UserDefaults.standard.set(showHUD, forKey: Defaults.showHUD) }
    }

    @Published var historyEnabled: Bool {
        didSet { UserDefaults.standard.set(historyEnabled, forKey: Defaults.historyEnabled) }
    }

    @Published var historyRetentionDays: Int {
        didSet { UserDefaults.standard.set(historyRetentionDays, forKey: Defaults.historyRetentionDays) }
    }

    @Published var verboseLogging: Bool {
        didSet {
            UserDefaults.standard.set(verboseLogging, forKey: Defaults.verboseLogging)
            FileLogger.shared.setEnabled(verboseLogging)
        }
    }

    @Published var writingAssistance: WritingAssistance {
        didSet { UserDefaults.standard.set(writingAssistance.rawValue, forKey: Defaults.writingAssistance) }
    }

    private init() {
        let d = UserDefaults.standard
        self.mode = Mode(rawValue: d.string(forKey: Defaults.mode) ?? "") ?? .hold
        // UserDefaults.integer returns 0 for missing keys, which isn't a valid keyCode,
        // so we go through `object(forKey:)` to detect "not set" and default to Right Option.
        let storedKey = d.object(forKey: Defaults.key) as? Int
        self.key = storedKey.flatMap(Key.init(rawValue:)) ?? .rightOption
        self.playStartSound = (d.object(forKey: Defaults.playStartSound) as? Bool) ?? true
        self.playStopSound = (d.object(forKey: Defaults.playStopSound) as? Bool) ?? false
        self.showHUD = (d.object(forKey: Defaults.showHUD) as? Bool) ?? true
        self.historyEnabled = (d.object(forKey: Defaults.historyEnabled) as? Bool) ?? true
        let storedRetention = d.object(forKey: Defaults.historyRetentionDays) as? Int
        self.historyRetentionDays = storedRetention ?? 90
        let verbose = (d.object(forKey: Defaults.verboseLogging) as? Bool) ?? false
        self.verboseLogging = verbose
        FileLogger.shared.setEnabled(verbose)
        let storedAssistance = d.string(forKey: Defaults.writingAssistance)
        self.writingAssistance = storedAssistance.flatMap(WritingAssistance.init(rawValue:)) ?? .standard
    }
}
