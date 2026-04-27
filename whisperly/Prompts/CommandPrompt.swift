import Foundation

nonisolated enum CommandPrompt {
    /// System prompt for command mode. The user spoke a verb-prefixed phrase
    /// like "bullet list: get milk, eggs, bread"; Haiku formats the content.
    /// `{DICTIONARY_JSON}` is filled at request time so the cached prefix
    /// stays warm and only the dictionary tail invalidates as the user's
    /// vocabulary grows.
    static let template: String = """
    You are Whisperly's command mode. The user spoke a command followed by content. Your job is to apply the command formatting to the content and return the result.

    Recognized commands (the user's speech may start with these):
    - "bullet list" / "bullets" / "list" → format content as a bulleted list
    - "numbered list" → format as numbered list
    - "email" / "email tone" → polished email body
    - "code" / "code block" → wrap in markdown code block, infer language
    - "summarize" / "summary" → 2-3 sentence summary
    - "table" → markdown table if structure is clear
    - "casual" / "informal" → casual rewrite
    - "formal" / "professional" → formal rewrite
    - "translate to X" → translate following content to X

    If no command is detected, treat the entire input as normal dictation.

    Output ONLY the formatted result. No preamble. Match the target app's formatting context.

    PERSONAL DICTIONARY:
    {DICTIONARY_JSON}
    """

    static func system(dictionaryJSON: String = "[]") -> String {
        template.replacingOccurrences(of: "{DICTIONARY_JSON}", with: dictionaryJSON)
    }

    /// Lightweight detection: do we believe the user spoke a command?
    /// Match against the start of the trimmed transcript, case-insensitive.
    static func looksLikeCommand(_ transcript: String) -> Bool {
        let lower = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        for prefix in commandPrefixes {
            if lower.hasPrefix(prefix) {
                // Require the command to be followed by punctuation/space — so
                // "bullet list: ..." matches but "bulletproof" doesn't.
                let next = lower.dropFirst(prefix.count).first
                if next == nil || next == ":" || next == " " || next == "," || next == "." {
                    return true
                }
            }
        }
        // "translate to <something>" — needs the whole pattern, not just "translate".
        if lower.hasPrefix("translate to ") {
            return true
        }
        return false
    }

    private static let commandPrefixes: [String] = [
        "bullet list", "bullets", "numbered list",
        "email tone", "email",
        "code block", "code",
        "summarize", "summary",
        "table",
        "casual", "informal",
        "formal", "professional",
    ]
}
