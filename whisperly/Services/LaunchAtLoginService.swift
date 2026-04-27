import Foundation
import ServiceManagement
import os

/// Wraps `SMAppService.mainApp` so the app can register/unregister itself
/// as a Login Item. macOS 13+ only — falls back to a no-op on older versions
/// (we target 14+ anyway, but keep the guard explicit).
@MainActor
enum LaunchAtLoginService {
    private static let logger = Logger(subsystem: "com.karim.whisperly", category: "LaunchAtLogin")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the new state on success; throws on failure.
    @discardableResult
    static func setEnabled(_ enabled: Bool) throws -> Bool {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        let now = isEnabled
        logger.info("Launch at login \(enabled ? "enabled" : "disabled", privacy: .public) → status=\(String(describing: SMAppService.mainApp.status), privacy: .public)")
        return now
    }
}
