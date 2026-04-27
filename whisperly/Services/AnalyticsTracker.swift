import Combine
import Foundation
import os

/// Derives usage analytics from the history database. Computes:
/// - words dictated (today / 7-day / all-time)
/// - dictation seconds (sum of audio durations)
/// - estimated WPM (cleaned word count ÷ dictation minutes)
/// - time saved (cleaned words ÷ baseline typing WPM, minus dictation time)
/// - daily streak (consecutive days with at least one dictation, ending today)
/// - per-day word counts for the chart
/// - per-app and per-hour-of-day breakdowns
///
/// Refreshes whenever HistoryStore.changeSubject fires.
@MainActor
final class AnalyticsTracker: ObservableObject {
    /// User can override in General settings; defaults to 40 WPM (a standard
    /// touch-typing baseline). Used to compute "time saved".
    @Published var typingWPMBaseline: Double = 40

    @Published private(set) var summary: Summary = .empty

    struct Summary: Equatable {
        var wordsToday: Int
        var wordsThisWeek: Int
        var wordsAllTime: Int
        var dictationSecondsAllTime: Double
        var averageWPM: Double
        var timeSavedMinutes: Double
        var streakDays: Int
        var dictationsAllTime: Int

        static let empty = Summary(
            wordsToday: 0,
            wordsThisWeek: 0,
            wordsAllTime: 0,
            dictationSecondsAllTime: 0,
            averageWPM: 0,
            timeSavedMinutes: 0,
            streakDays: 0,
            dictationsAllTime: 0
        )
    }

    struct DailyPoint: Identifiable, Equatable {
        var id: Date { date }
        let date: Date
        let words: Int
        let wpm: Double?
    }

    struct AppBreakdown: Identifiable, Equatable {
        var id: String { app }
        let app: String
        let count: Int
    }

    struct HourBreakdown: Identifiable, Equatable {
        var id: Int { hour }
        let hour: Int
        let count: Int
    }

    @Published private(set) var dailyPoints: [DailyPoint] = []
    @Published private(set) var topApps: [AppBreakdown] = []
    @Published private(set) var hourBreakdown: [HourBreakdown] = []

    private let store: HistoryStore?
    private let logger = Logger(subsystem: "com.karim.whisperly", category: "Analytics")
    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?

    init(store: HistoryStore?) {
        self.store = store
        if let baseline = UserDefaults.standard.object(forKey: "analytics.typingBaselineWPM") as? Double {
            typingWPMBaseline = baseline
        }
        // Persist baseline changes.
        $typingWPMBaseline
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "analytics.typingBaselineWPM") }
            .store(in: &cancellables)
        // Recompute on history change.
        store?.changeSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
    }

    func refresh() {
        guard let store else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self, store, baseline = typingWPMBaseline] in
            do {
                let snapshot = try await Self.computeSnapshot(store: store, baselineWPM: baseline)
                if Task.isCancelled { return }
                guard let self else { return }
                self.summary = snapshot.summary
                self.dailyPoints = snapshot.dailyPoints
                self.topApps = snapshot.topApps
                self.hourBreakdown = snapshot.hourBreakdown
            } catch {
                self?.logger.error("Analytics refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Computation

    private struct Snapshot: Sendable {
        let summary: Summary
        let dailyPoints: [DailyPoint]
        let topApps: [AppBreakdown]
        let hourBreakdown: [HourBreakdown]
    }

    nonisolated private static func computeSnapshot(store: HistoryStore, baselineWPM: Double) async throws -> Snapshot {
        let entries = try await store.analyticsRows()
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let weekAgo = cal.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday

        var wordsToday = 0
        var wordsThisWeek = 0
        var wordsAllTime = 0
        var secondsAllTime: Double = 0

        var dailyMap: [Date: (words: Int, seconds: Double)] = [:]
        var appCounts: [String: Int] = [:]
        var hourCounts: [Int: Int] = [:]

        for entry in entries {
            let words = entry.wordCount ?? 0
            let dur = entry.audioDurationSeconds ?? 0
            wordsAllTime += words
            secondsAllTime += dur

            let day = cal.startOfDay(for: entry.timestamp)
            var bucket = dailyMap[day] ?? (0, 0)
            bucket.words += words
            bucket.seconds += dur
            dailyMap[day] = bucket

            if day >= startOfToday { wordsToday += words }
            if day >= weekAgo { wordsThisWeek += words }

            if let app = entry.targetApp, !app.isEmpty {
                appCounts[app, default: 0] += 1
            }
            let hour = cal.component(.hour, from: entry.timestamp)
            hourCounts[hour, default: 0] += 1
        }

        // Streak: count consecutive days back from today with at least one entry.
        var streak = 0
        var cursor = startOfToday
        while dailyMap[cursor]?.words ?? 0 > 0 {
            streak += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }

        let dictationMinutes = secondsAllTime / 60
        let averageWPM = dictationMinutes > 0 ? Double(wordsAllTime) / dictationMinutes : 0
        let typingMinutes = baselineWPM > 0 ? Double(wordsAllTime) / baselineWPM : 0
        let savedMinutes = max(0, typingMinutes - dictationMinutes)

        let summary = Summary(
            wordsToday: wordsToday,
            wordsThisWeek: wordsThisWeek,
            wordsAllTime: wordsAllTime,
            dictationSecondsAllTime: secondsAllTime,
            averageWPM: averageWPM,
            timeSavedMinutes: savedMinutes,
            streakDays: streak,
            dictationsAllTime: entries.count
        )

        // Daily points: last 30 days, padded with zeros.
        var dailyPoints: [DailyPoint] = []
        for offset in stride(from: 29, through: 0, by: -1) {
            guard let date = cal.date(byAdding: .day, value: -offset, to: startOfToday) else { continue }
            let bucket = dailyMap[date] ?? (0, 0)
            let mins = bucket.seconds / 60
            let wpm: Double? = mins > 0 ? Double(bucket.words) / mins : nil
            dailyPoints.append(DailyPoint(date: date, words: bucket.words, wpm: wpm))
        }

        let topApps = appCounts
            .map { AppBreakdown(app: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(8)

        let hours = (0..<24).map { hour in
            HourBreakdown(hour: hour, count: hourCounts[hour] ?? 0)
        }

        return Snapshot(
            summary: summary,
            dailyPoints: dailyPoints,
            topApps: Array(topApps),
            hourBreakdown: hours
        )
    }
}

