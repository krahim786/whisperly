import Combine
import Foundation
import Sparkle
import SwiftUI
import os

/// Wraps Sparkle's `SPUStandardUpdaterController` and exposes the small slice
/// of API the rest of Whisperly needs: a "can check right now?" flag for
/// disabling the menu item while a check is in flight, the human-readable
/// last-check date for the Settings UI, and a method that triggers a manual
/// check.
///
/// Configuration lives in Info.plist (set via build settings):
///   - `SUFeedURL`            — URL to your appcast.xml
///   - `SUPublicEDKey`        — base64-encoded EdDSA public key (paired with
///                              the private key you sign each release with)
///   - `SUEnableAutomaticChecks` (bool, default true)
///   - `SUScheduledCheckInterval` (seconds, default 86400 = once per day)
///
/// See SPARKLE.md for the one-time keypair-generation + appcast-hosting setup.
@MainActor
final class UpdateService: ObservableObject {
    @Published private(set) var canCheckForUpdates: Bool = false
    @Published var automaticChecks: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticChecks }
    }

    /// Last successful update-check date, formatted for display. nil if
    /// Sparkle has never run a check on this install.
    var lastCheckDateText: String? {
        guard let date = controller.updater.lastUpdateCheckDate else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// True if the Info.plist still has the placeholder feed URL — surfaces
    /// in the Settings UI so the user knows updates won't actually work yet.
    let isFeedConfigured: Bool

    private let controller: SPUStandardUpdaterController
    private let logger = Logger(subsystem: "com.karim.whisperly", category: "UpdateService")
    private var cancellables = Set<AnyCancellable>()

    init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.automaticChecks = controller.updater.automaticallyChecksForUpdates

        // Detect placeholder Info.plist value so the UI can warn that the
        // appcast hasn't been wired up yet.
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        self.isFeedConfigured = !feed.isEmpty
            && !feed.contains("example.com")
            && !feed.contains("PUT_YOUR")

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
            .store(in: &cancellables)

        if !isFeedConfigured {
            logger.info("Sparkle SUFeedURL is a placeholder — auto-update is wired but not yet active. See SPARKLE.md.")
        }
    }

    /// Triggers a foreground check that shows Sparkle's standard UI ("Up to
    /// date" / "New version available"). Wired to the Help → "Check for
    /// Updates…" menu item.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
