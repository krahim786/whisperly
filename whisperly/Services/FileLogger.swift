import Foundation
import os

/// Thread-safe append-only logger to `~/Library/Logs/Whisperly/whisperly-YYYY-MM-DD.log`.
/// Only writes when verbose mode is enabled (HotkeyConfig.verboseLogging).
/// Wrapped in a serial queue + handle reuse for cheap appends; rotates daily
/// based on the local-calendar date.
///
/// This sits *alongside* `os.Logger`, not instead of it. The OSLog stream is
/// always available via Console.app; the file mirror is for users who want
/// to bundle a log when filing an issue.
nonisolated final class FileLogger: @unchecked Sendable {
    static let shared = FileLogger()

    private let queue = DispatchQueue(label: "com.karim.whisperly.filelog")
    private let folder: URL?
    private let osLogger = Logger(subsystem: "com.karim.whisperly", category: "FileLogger")

    // Mutated only on `queue`.
    private var fileHandle: FileHandle?
    private var currentDateString: String = ""
    private var enabled: Bool = false

    private init() {
        let fm = FileManager.default
        do {
            let logs = try fm.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("Whisperly", isDirectory: true)
            try fm.createDirectory(at: logs, withIntermediateDirectories: true)
            self.folder = logs
        } catch {
            self.folder = nil
            osLogger.error("FileLogger init failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Folder where logs land. May be nil if creation failed at init.
    var logFolderURL: URL? { folder }

    /// Toggle file logging. Off by default.
    func setEnabled(_ on: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.enabled = on
            if !on {
                self.closeHandle()
            }
        }
    }

    /// Append a structured line. Format:
    /// `2026-04-27 14:32:11.123 [category] level: message`
    func write(category: String, level: String, _ message: String) {
        queue.async { [weak self] in
            guard let self, self.enabled, let folder = self.folder else { return }
            self.ensureHandle(folder: folder)
            let line = "\(Self.timestampFormatter.string(from: Date())) [\(category)] \(level): \(message)\n"
            if let data = line.data(using: .utf8) {
                self.fileHandle?.write(data)
            }
        }
    }

    /// Convenience for callers that already have an os.Logger but also want
    /// the line in the file. Pass-through if verbose is off.
    func mirror(_ category: String, _ level: OSLogType, _ message: String) {
        let levelString: String
        switch level {
        case .error, .fault: levelString = "error"
        case .info: levelString = "info"
        case .debug: levelString = "debug"
        default: levelString = "default"
        }
        write(category: category, level: levelString, message)
    }

    // MARK: - Internals

    private func ensureHandle(folder: URL) {
        let today = Self.fileDateFormatter.string(from: Date())
        if today != currentDateString || fileHandle == nil {
            closeHandle()
            let url = folder.appendingPathComponent("whisperly-\(today).log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            fileHandle = try? FileHandle(forWritingTo: url)
            _ = try? fileHandle?.seekToEnd()
            currentDateString = today
        }
    }

    private func closeHandle() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
