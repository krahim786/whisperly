import SwiftUI

/// SwiftUI content for the HUD panel. Driven entirely by AppState.
struct HUDView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            stateIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(stateText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if case .error(let message) = appState.phase {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            if case .recording = appState.phase {
                AmplitudeBars(values: appState.amplitudeHistory)
                    .frame(width: 84, height: 24)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch appState.phase {
        case .idle:
            Image(systemName: "mic")
                .foregroundStyle(.secondary)
        case .recording:
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .stroke(.red.opacity(0.4), lineWidth: 4)
                        .scaleEffect(pulseScale)
                        .opacity(2 - pulseScale)
                )
                .animation(.easeOut(duration: 1.0).repeatForever(autoreverses: false), value: pulseScale)
                .onAppear { pulseScale = 2.4 }
        case .transcribing, .cleaning:
            ProgressView()
                .controlSize(.small)
        case .pasting:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @State private var pulseScale: CGFloat = 1.0

    private var stateText: String {
        switch appState.phase {
        case .idle: return "Whisperly"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .cleaning: return "Polishing"
        case .pasting: return "Pasting"
        case .error: return "Error"
        }
    }
}

/// Live RMS-amplitude visualization. Scrolling bars: newest on the right.
struct AmplitudeBars: View {
    let values: [Float]
    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 2
    private let barCount = 20

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(barColor(for: normalized(at: i)))
                        .frame(width: barWidth, height: max(2, normalized(at: i) * geo.size.height))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func normalized(at i: Int) -> CGFloat {
        // Right-align the data into the fixed-width bar strip.
        let backFromEnd = barCount - 1 - i
        let dataIndex = values.count - 1 - backFromEnd
        guard dataIndex >= 0, dataIndex < values.count else { return 0 }
        // Map RMS (0...~0.5) to a perceptually-friendly height with a soft curve.
        let raw = CGFloat(values[dataIndex])
        let scaled = min(1.0, max(0.0, raw * 4))
        return scaled
    }

    private func barColor(for h: CGFloat) -> Color {
        h > 0.6 ? .red : .accentColor
    }
}
