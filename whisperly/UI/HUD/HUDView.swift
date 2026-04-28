import SwiftUI

/// Pill-shaped HUD: dark glassy capsule with a tall gradient waveform on
/// the left and a large state label on the right.
struct HUDView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 18) {
            waveform
                .frame(width: 96, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                if case .recording = appState.phase, !appState.liveTranscript.isEmpty {
                    // Live preview wins the prime label slot during recording —
                    // it's what the user actually wants to see.
                    Text(appState.liveTranscript)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .truncationMode(.head)
                        .animation(.easeOut(duration: 0.12), value: appState.liveTranscript)
                } else {
                    Text(stateText)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if case .error(let message) = appState.phase {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .truncationMode(.tail)
                } else if let mode = appState.modeDisplay {
                    Text(mode)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.65, green: 0.55, blue: 0.95))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pillBackground)
    }

    // MARK: - Background

    private var pillBackground: some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.10, blue: 0.13),
                        Color(red: 0.06, green: 0.06, blue: 0.09),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: 8)
    }

    // MARK: - Waveform

    @ViewBuilder
    private var waveform: some View {
        switch appState.phase {
        case .idle:
            EmptyView()
        case .recording:
            GradientBars(values: appState.amplitudeHistory)
        case .transcribing, .cleaning, .pasting:
            AnimatedGradientBars()
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Label

    private var stateText: String {
        switch appState.phase {
        case .idle: return "Whisperly"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .cleaning: return "Polishing…"
        case .pasting: return "Pasting…"
        case .error: return "Error"
        }
    }
}

// MARK: - Gradient

/// Vertical blue → purple → pink gradient used for every active bar.
private let barGradient = LinearGradient(
    colors: [
        Color(red: 0.32, green: 0.55, blue: 0.96),
        Color(red: 0.55, green: 0.39, blue: 0.95),
        Color(red: 0.93, green: 0.45, blue: 0.74),
    ],
    startPoint: .bottom,
    endPoint: .top
)

// MARK: - Live amplitude bars

/// Live audio-reactive bars driven by `AppState.amplitudeHistory` (RMS values
/// 0…1, sliding window). Each bar is a vertical capsule filled with the
/// brand gradient. Newest sample on the right.
struct GradientBars: View {
    let values: [Float]

    private let barCount = 14
    private let barWidth: CGFloat = 4
    private let spacing: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule(style: .continuous)
                        .fill(barGradient)
                        .frame(width: barWidth, height: barHeight(at: i, max: geo.size.height))
                        .animation(.easeOut(duration: 0.08), value: heightSeed(at: i))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func heightSeed(at i: Int) -> Float {
        let backFromEnd = barCount - 1 - i
        let dataIndex = values.count - 1 - backFromEnd
        guard dataIndex >= 0, dataIndex < values.count else { return 0 }
        return values[dataIndex]
    }

    private func barHeight(at i: Int, max h: CGFloat) -> CGFloat {
        let raw = CGFloat(heightSeed(at: i))
        // Boost low values so quiet speech still produces visible motion.
        let scaled = min(1.0, max(0.0, raw * 5.0))
        // Always show at least a sliver so the bars never collapse to zero.
        return max(4, scaled * h)
    }
}

// MARK: - Synthetic animation for non-recording phases

/// Smooth synthetic wave for transcribing / cleaning / pasting phases — keeps
/// the HUD feeling alive while we wait on network/IPC. Driven by
/// `TimelineView(.animation)` for ~60fps continuous updates without observable
/// state.
struct AnimatedGradientBars: View {
    private let barCount = 14
    private let barWidth: CGFloat = 4
    private let spacing: CGFloat = 4

    var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { geo in
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { i in
                        Capsule(style: .continuous)
                            .fill(barGradient)
                            .frame(
                                width: barWidth,
                                height: animatedHeight(
                                    bar: i,
                                    time: context.date.timeIntervalSinceReferenceDate,
                                    max: geo.size.height
                                )
                            )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    /// Sin-wave with per-bar phase offset; smooths into a flowing wave.
    private func animatedHeight(bar: Int, time: TimeInterval, max h: CGFloat) -> CGFloat {
        let phase = Double(bar) * 0.55
        let speed = 3.5
        let raw = (sin(time * speed + phase) + 1) / 2  // 0…1
        let value = 0.35 + raw * 0.6                   // 0.35…0.95 — never collapse to 0
        return max(4, CGFloat(value) * h)
    }
}
