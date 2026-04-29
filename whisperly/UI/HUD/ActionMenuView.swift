import SwiftUI

/// Compact horizontal menu of transformation actions. Sits above the HUD
/// after a Right-Option-+-Shift dictation. Click any button → that style is
/// returned via the `onChoice` closure, the menu dismisses, and AppState
/// runs Haiku.transform with the chosen style.
struct ActionMenuView: View {
    let onChoice: (ActionMenuStyle) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ActionMenuStyle.allCases) { style in
                ActionButton(style: style, onTap: { onChoice(style) })
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.12, blue: 0.15),
                            Color(red: 0.08, green: 0.08, blue: 0.11),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: 8)
        )
    }
}

private struct ActionButton: View {
    let style: ActionMenuStyle
    let onTap: () -> Void
    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Image(systemName: style.symbolName)
                    .font(.system(size: 18, weight: .medium))
                Text(style.label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(width: 76, height: 56)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(isHovering ? 0.12 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.white.opacity(isHovering ? 0.18 : 0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
