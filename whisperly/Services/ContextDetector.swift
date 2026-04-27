import AppKit
import Foundation

/// Day 1: only resolves the frontmost application's user-facing name.
/// Day 3 will add Accessibility-based selection detection.
@MainActor
final class ContextDetector {
    func frontmostAppName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
    }
}
