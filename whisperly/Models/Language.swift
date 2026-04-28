import Foundation

/// Languages Whisperly explicitly recognizes. Used both as a Whisper
/// `language` hint and as a target for Haiku translation. Whisper supports
/// many more (~98), but exposing all is overkill — these cover ~95% of
/// likely user demand.
nonisolated enum Language: String, CaseIterable, Codable, Identifiable, Sendable {
    case auto
    case english
    case spanish
    case french
    case german
    case italian
    case portuguese
    case dutch
    case russian
    case polish
    case turkish
    case arabic
    case hindi
    case chineseSimplified
    case japanese
    case korean
    case vietnamese
    case thai
    case indonesian

    var id: String { rawValue }

    /// English-language label (used in settings UI).
    var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .dutch: return "Dutch"
        case .russian: return "Russian"
        case .polish: return "Polish"
        case .turkish: return "Turkish"
        case .arabic: return "Arabic"
        case .hindi: return "Hindi"
        case .chineseSimplified: return "Chinese (Simplified)"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .vietnamese: return "Vietnamese"
        case .thai: return "Thai"
        case .indonesian: return "Indonesian"
        }
    }

    /// Native-language label (e.g. "Español") shown alongside the English
    /// name in the picker so non-English speakers can find their language.
    var nativeName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .english: return "English"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .italian: return "Italiano"
        case .portuguese: return "Português"
        case .dutch: return "Nederlands"
        case .russian: return "Русский"
        case .polish: return "Polski"
        case .turkish: return "Türkçe"
        case .arabic: return "العربية"
        case .hindi: return "हिन्दी"
        case .chineseSimplified: return "简体中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .vietnamese: return "Tiếng Việt"
        case .thai: return "ไทย"
        case .indonesian: return "Bahasa Indonesia"
        }
    }

    /// Combined label for menu rows: "Spanish (Español)".
    var pickerLabel: String {
        switch self {
        case .auto, .english:
            return displayName
        default:
            return "\(displayName) (\(nativeName))"
        }
    }

    /// ISO 639-1 code for Whisper's `language` parameter. nil = omit the
    /// field, letting Whisper auto-detect from the audio.
    var whisperCode: String? {
        switch self {
        case .auto: return nil
        case .english: return "en"
        case .spanish: return "es"
        case .french: return "fr"
        case .german: return "de"
        case .italian: return "it"
        case .portuguese: return "pt"
        case .dutch: return "nl"
        case .russian: return "ru"
        case .polish: return "pl"
        case .turkish: return "tr"
        case .arabic: return "ar"
        case .hindi: return "hi"
        case .chineseSimplified: return "zh"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .vietnamese: return "vi"
        case .thai: return "th"
        case .indonesian: return "id"
        }
    }

    /// Languages valid as an *input* — includes auto-detect.
    static var inputOptions: [Language] { allCases }

    /// Languages valid as a *target* — excludes auto-detect (translation
    /// must specify a target).
    static var outputOptions: [Language] { allCases.filter { $0 != .auto } }
}
