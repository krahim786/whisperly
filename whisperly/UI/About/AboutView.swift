import SwiftUI

struct AboutView: View {
    @ObservedObject var updates: UpdateService
    @Environment(\.openURL) private var openURL

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 16) {
            // Uses the app's bundled icon (the one in Assets.xcassets/AppIcon).
            // Falls back to an SF Symbol if the icon image isn't available
            // (e.g. running unbundled in a SwiftUI preview).
            Group {
                if let appIcon = NSApp?.applicationIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 96, height: 96)
                } else {
                    Image(systemName: "mic.badge.plus")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.top, 8)

            VStack(spacing: 4) {
                Text("Whisperly")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("Version \(version) (\(build))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Hold a hotkey, speak naturally, and Whisperly turns your voice into polished text — pasted right into whatever app you're using.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            updatesSection

            HStack(spacing: 24) {
                Button("Privacy") {
                    if let url = Self.privacyDocURL { openURL(url) }
                }
                Button("Acknowledgements") {
                    NotificationCenter.default.post(name: .showAcknowledgements, object: nil)
                }
                Button("GitHub") {
                    openURL(URL(string: "https://github.com/anthropics/claude-code")!)
                }
            }
            .controlSize(.regular)

            Spacer(minLength: 0)

            Text("Built with ❤️ on macOS · Powered by Groq Whisper + Claude Haiku")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 440, height: 440)
    }

    /// Updates section — last-check date on the left, manual-check button on
    /// the right. The button reflects `canCheckForUpdates` so it disables
    /// while a check is in flight. A subtle warning replaces the date when
    /// the appcast feed URL hasn't been configured yet (placeholder Info.plist
    /// value), so users on a dev build know auto-update isn't actually wired.
    private var updatesSection: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Updates")
                    .font(.subheadline.weight(.medium))
                Text(updatesCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            Button("Check Now") {
                updates.checkForUpdates()
            }
            .disabled(!updates.canCheckForUpdates || !updates.isFeedConfigured)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.05), lineWidth: 1)
        )
        .frame(maxWidth: 360)
    }

    private var updatesCaption: String {
        if !updates.isFeedConfigured {
            return "Auto-update isn't configured for this build."
        }
        if let last = updates.lastCheckDateText {
            return "Last checked \(last)"
        }
        return "Never checked — click to look for updates"
    }

    /// Resolves the bundled `PRIVACY.md` if present (Day 7 ships it at the
    /// project root for now; the bundle copy is a v1.1 polish task).
    private static var privacyDocURL: URL? {
        if let bundled = Bundle.main.url(forResource: "PRIVACY", withExtension: "md") {
            return bundled
        }
        return URL(string: "https://github.com/anthropics/claude-code")
    }
}

extension Notification.Name {
    static let showAbout = Notification.Name("com.karim.whisperly.showAbout")
    static let showAcknowledgements = Notification.Name("com.karim.whisperly.showAcknowledgements")
    static let showHelpCheatSheet = Notification.Name("com.karim.whisperly.showHelpCheatSheet")
}

#Preview {
    AboutView(updates: UpdateService())
}
