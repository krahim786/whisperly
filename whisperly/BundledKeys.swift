import Foundation

/// Optional keys baked into a distribution build. `nil` for normal dev builds
/// — `KeychainService` will fall through to whatever the user pasted into
/// Settings. When set (via `scripts/build-local-dmg.sh` with the
/// `WHISPERLY_BUNDLED_*` env vars), the keys are used as a fallback so
/// family members don't have to provide their own.
///
/// ⚠️  Anything in this file ships in the .app binary as plain text and is
/// trivially extractable via `strings`. Never embed keys you wouldn't be
/// willing to publicly disclose. Read SIGNING.md → "Embedding API keys for
/// family use" before turning this on.
///
/// This committed file always declares `nil`; the build script overwrites
/// it at archive time and restores it on exit so real keys never reach git.
nonisolated enum BundledKeys {
    static let groqAPIKey: String? = nil
    static let anthropicAPIKey: String? = nil

    /// True if the build was archived with at least one bundled key. Used by
    /// onboarding to skip the API-keys step when keys are pre-baked.
    static var hasAnyBundled: Bool {
        (groqAPIKey?.isEmpty == false) || (anthropicAPIKey?.isEmpty == false)
    }
}
