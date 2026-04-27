import SwiftUI

struct AboutView: View {
    @Environment(\.openURL) private var openURL

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 18) {
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
        .frame(width: 420, height: 360)
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
    AboutView()
}
