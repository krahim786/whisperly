import SwiftUI

/// Two-row menu of transformation actions. Sits above the HUD after a
/// Right-Option-+-Shift dictation (or a quick refine tap). Click any button
/// → that style is returned via the `onChoice` closure, the menu dismisses,
/// and AppState runs Haiku.transform with the chosen style.
///
/// Row 1 is tone/grammar (Grammar / Personal / Formal / Shorter), row 2 is
/// formatting/structure (Bullets / Email / Summary). The split mirrors the
/// `ActionMenuStyle` enum order — first 4 cases on top, remaining on bottom,
/// centered. If we ever add another style, slot it in the appropriate row.
struct ActionMenuView: View {
    let onChoice: (ActionMenuStyle) -> Void

    private static let topRow: [ActionMenuStyle] = [.grammar, .personal, .formal, .shorter]
    private static let bottomRow: [ActionMenuStyle] = [.bulletList, .email, .summarize]

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Self.topRow) { style in
                    ActionButton(style: style, onTap: { onChoice(style) })
                }
            }
            HStack(spacing: 6) {
                ForEach(Self.bottomRow) { style in
                    ActionButton(style: style, onTap: { onChoice(style) })
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
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
