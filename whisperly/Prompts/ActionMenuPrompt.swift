import Foundation

/// Transformations the user can pick from the post-dictation action menu
/// (triggered by holding Right Option + Shift while speaking). Order here
/// drives the visual order in the menu.
nonisolated enum ActionMenuStyle: String, CaseIterable, Identifiable, Sendable {
    case grammar
    case personal
    case formal
    case shorter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .grammar: return "Grammar"
        case .personal: return "Personal"
        case .formal: return "Formal"
        case .shorter: return "Shorter"
        }
    }

    /// SF Symbol name for the menu button.
    var symbolName: String {
        switch self {
        case .grammar: return "checkmark.seal"
        case .personal: return "person.crop.circle"
        case .formal: return "briefcase"
        case .shorter: return "arrow.down.right.and.arrow.up.left"
        }
    }

    /// One-paragraph instruction inlined into the system prompt — describes
    /// the desired transformation without prescribing exact wording.
    var instruction: String {
        switch self {
        case .grammar:
            return "Fix grammar errors — article use, verb tenses and agreement, prepositions, word order, and awkward L2 phrasing — while preserving the user's voice, tone, register, and approximate length. Don't add or remove information; just clean the language."
        case .personal:
            return "Rewrite in a casual, friendly, conversational tone — like a message to a friend. Loosen up formal sentence structure, use contractions where natural, drop hedging. Preserve the meaning and roughly the length."
        case .formal:
            return "Rewrite in a polished, professional, formal tone — like a business email to a colleague. Tighten casual phrasing, prefer complete sentences, remove contractions where natural. Preserve the meaning and roughly the length."
        case .shorter:
            return "Rewrite to be roughly half the length while preserving the core meaning. Cut filler, redundancy, hedging, and side commentary. Keep the same prose form — don't summarize into bullets or headlines."
        }
    }
}

nonisolated enum ActionMenuPrompt {
    /// System prompt for transform mode. Like DictationPrompt, the cached
    /// prefix is stable; only the {INSTRUCTION} and {DICTIONARY_JSON} tails
    /// change per request, which is fine for cache hit behavior since each
    /// (style, dictionary) combo gets its own warm cache slot.
    static let template: String = """
    You are Whisperly's transform mode. The user dictated text via voice and explicitly chose a transformation to apply. Apply the instruction faithfully and return ONLY the transformed text.

    Apply this transformation:
    {INSTRUCTION}

    RULES:
    - Output ONLY the transformed text. No preamble, no quotes, no explanation, no markdown unless the target app uses markdown.
    - Apply correct punctuation and capitalization for the resulting text.
    - Match the formatting context of the target app:
      - Slack, Discord, iMessage, Messages: conversational, casual, contractions OK
      - Mail, Gmail, Outlook, Spark: proper sentences, paragraph breaks
      - Xcode, VS Code, Cursor, Terminal, iTerm: code-friendly, no end punctuation on code lines
      - Notes, Notion, Obsidian, Bear, Craft: clean prose, paragraph breaks
      - Default: clean prose with standard punctuation

    PERSONAL DICTIONARY (preserve exact spelling/casing — never translate or paraphrase these):
    {DICTIONARY_JSON}
    """

    static func system(style: ActionMenuStyle, dictionaryJSON: String = "[]") -> String {
        template
            .replacingOccurrences(of: "{INSTRUCTION}", with: style.instruction)
            .replacingOccurrences(of: "{DICTIONARY_JSON}", with: dictionaryJSON)
    }
}
