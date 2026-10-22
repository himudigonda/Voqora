import SwiftUI

enum VoqoraCardStyle {
    case filled
    case elevated
    case outlined
}

private struct CardBackground<S: InsettableShape>: ViewModifier {
    let style: VoqoraCardStyle
    let shape: S
    @Environment(\.voqoraTheme) private var theme

    func body(content: Content) -> some View {
        content
            .background(fill, in: shape)
            .overlay {
                if style == .outlined {
                    shape.strokeBorder(theme.outlineVariant, lineWidth: 1)
                }
            }
            .compositingGroup()
            .shadow(
                color: style == .elevated ? .black.opacity(0.10) : .clear,
                radius: style == .elevated ? 10 : 0,
                y: style == .elevated ? 3 : 0
            )
    }

    private var fill: Color {
        switch style {
        case .filled: theme.surfaceContainer
        case .elevated: theme.surfaceContainerLow
        case .outlined: .clear
        }
    }
}

extension View {
    func voqoraCardBackground(_ style: VoqoraCardStyle = .filled, radius: CGFloat = Theme.Shape.lg) -> some View {
        modifier(CardBackground(style: style, shape: RoundedRectangle(cornerRadius: radius, style: .continuous)))
    }
}

struct VoqoraCard<Content: View>: View {
    let style: VoqoraCardStyle
    let padding: CGFloat
    let content: Content

    init(
        _ style: VoqoraCardStyle = .filled,
        padding: CGFloat = Theme.Space.card,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .voqoraCardBackground(style)
    }
}
