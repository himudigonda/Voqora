import SwiftUI

struct AccentSwatchButton: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) var colorSchemeContrast
    @Environment(\.voqoraTheme) private var theme
    let option: AccentColorOption
    let isSelected: Bool
    let action: () -> Void

    private var colors: (accent: Color, onAccent: Color) {
        let increased = colorSchemeContrast == .increased
        return (
            Palette.accentColors(for: option, appearance: colorScheme, increaseContrast: increased).accent,
            Palette.onAccentColor(for: option, appearance: colorScheme, increaseContrast: increased)
        )
    }

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(colors.accent)
                .frame(width: 32, height: 32)
                .overlay(
                    Circle()
                        .strokeBorder(theme.onSurface, lineWidth: isSelected ? 2 : 0)
                        .padding(-4)
                )
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(colors.onAccent)
                    }
                }
                .padding(4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.selection, value: isSelected)
        .accessibilityLabel(option.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(option.displayName)
    }
}
