import Charts
import SwiftUI

struct StatsWindowView: View {
    @ObservedObject var analytics: AnalyticsTracker

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                summaryCards
                Divider()
                wordsPerDayChart
                Divider()
                wpmChart
                Divider()
                HStack(alignment: .top, spacing: 24) {
                    topAppsChart
                    hourBreakdownChart
                }
                Divider()
                baselineControl
            }
            .padding(20)
        }
        .frame(minWidth: 720, minHeight: 540)
        .navigationTitle("Whisperly Stats")
        .onAppear { analytics.refresh() }
    }

    // MARK: - Summary

    private var summaryCards: some View {
        let s = analytics.summary
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            statCard(label: "Today", value: "\(s.wordsToday)", unit: "words", accent: .blue)
            statCard(label: "This week", value: "\(s.wordsThisWeek)", unit: "words", accent: .purple)
            statCard(label: "All time", value: "\(s.wordsAllTime)", unit: "words", accent: .green)
            statCard(label: "Streak", value: "\(s.streakDays)", unit: s.streakDays == 1 ? "day" : "days", accent: .orange)
            statCard(label: "Avg WPM", value: String(format: "%.0f", s.averageWPM), unit: "vs \(Int(analytics.typingWPMBaseline)) typed", accent: .teal)
            statCard(label: "Time saved", value: formatMinutes(s.timeSavedMinutes), unit: "vs typing", accent: .pink)
        }
    }

    private func statCard(label: String, value: String, unit: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.06))
        )
    }

    // MARK: - Words / day chart

    private var wordsPerDayChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Words per day")
                .font(.headline)
            Chart(analytics.dailyPoints) { point in
                BarMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("Words", point.words)
                )
                .foregroundStyle(Color.accentColor.gradient)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 180)
        }
    }

    // MARK: - WPM trend

    private var wpmChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WPM trend (last 30 days)")
                .font(.headline)
            Chart {
                ForEach(analytics.dailyPoints.compactMap { p in p.wpm.map { (p.date, $0) } }, id: \.0) { item in
                    LineMark(
                        x: .value("Day", item.0, unit: .day),
                        y: .value("WPM", item.1)
                    )
                    .foregroundStyle(.teal)
                    PointMark(
                        x: .value("Day", item.0, unit: .day),
                        y: .value("WPM", item.1)
                    )
                    .foregroundStyle(.teal)
                }
                RuleMark(y: .value("Typing baseline", analytics.typingWPMBaseline))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("typing baseline")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 180)
        }
    }

    // MARK: - Top apps

    private var topAppsChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top apps")
                .font(.headline)
            if analytics.topApps.isEmpty {
                emptyChart("No data yet.")
            } else {
                Chart(analytics.topApps) { app in
                    BarMark(
                        x: .value("Count", app.count),
                        y: .value("App", app.app)
                    )
                    .foregroundStyle(.purple.gradient)
                }
                .frame(height: 180)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Hour of day

    private var hourBreakdownChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Time of day")
                .font(.headline)
            Chart(analytics.hourBreakdown) { hb in
                BarMark(
                    x: .value("Hour", hb.hour),
                    y: .value("Count", hb.count)
                )
                .foregroundStyle(.orange.gradient)
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Int.self) {
                            Text(formatHour(v))
                                .font(.caption2)
                        }
                    }
                }
            }
            .frame(height: 180)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Baseline control

    private var baselineControl: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Typing baseline:")
                .font(.subheadline)
            Slider(value: $analytics.typingWPMBaseline, in: 20...120, step: 5) {
                EmptyView()
            } minimumValueLabel: {
                Text("20").font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("120").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 280)
            Text("\(Int(analytics.typingWPMBaseline)) WPM")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Text("Adjusts the \"time saved\" calculation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: analytics.typingWPMBaseline) { _, _ in
            analytics.refresh()
        }
    }

    private func emptyChart(_ message: String) -> some View {
        VStack {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 180)
    }

    private func formatHour(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        guard let date = Calendar.current.date(from: components) else { return "\(hour)" }
        let f = DateFormatter()
        f.dateFormat = "h a"
        return f.string(from: date)
    }

    private func formatMinutes(_ minutes: Double) -> String {
        if minutes < 60 {
            return String(format: "%.0fm", minutes)
        }
        let hours = Int(minutes / 60)
        let m = Int(minutes.truncatingRemainder(dividingBy: 60))
        return "\(hours)h \(m)m"
    }
}
