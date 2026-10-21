import SwiftUI

enum VoqoraButtonKind {
    case filled
    case tonal
    case outlined
    case text
    case icon
    case iconTonal
    case fabExtended
}

struct VoqoraButtonStyle: ButtonStyle {
    let kind: VoqoraButtonKind

    func makeBody(configuration: Configuration) -> some View {
        VoqoraButtonBody(kind: kind, configuration: configuration)
    }
}

private struct VoqoraButtonBody: View {
    let kind: VoqoraButtonKind
    let configuration: ButtonStyle.Configuration

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(vm.font(kind == .fabExtended ? .titleSmall : .label))
            .labelStyle(VoqoraButtonLabelStyle(spacing: kind == .fabExtended ? 10 : 8))
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: minimumWidth, minHeight: height)
            .background(background, in: shape)
            .overlay { stateLayer }
            .overlay {
                if kind == .outlined {
                    Capsule().strokeBorder(theme.outline, lineWidth: 1)
                }
            }
            .compositingGroup()
            .shadow(color: kind == .fabExtended ? .black.opacity(0.14) : .clear, radius: 8, y: 3)
            .opacity(isEnabled ? 1 : 0.38)
            .contentShape(shape)
            .animation(Theme.Motion.hover, value: isHovering)
            .animation(Theme.Motion.hover, value: configuration.isPressed)
            .onHover { isHovering = $0 }
    }

    private var isCircle: Bool {
        kind == .icon || kind == .iconTonal
    }

    private var shape: AnyShape {
        switch kind {
        case .fabExtended: AnyShape(RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
        case .icon, .iconTonal: AnyShape(Circle())
        default: AnyShape(Capsule())
        }
    }

    private var height: CGFloat {
        switch kind {
        case .fabExtended: 48
        case .icon, .iconTonal: 40
        default: 36
        }
    }

    private var minimumWidth: CGFloat? {
        isCircle ? 40 : nil
    }

    private var horizontalPadding: CGFloat {
        switch kind {
        case .fabExtended: 20
        case .icon, .iconTonal: 0
        case .text: 12
        default: 20
        }
    }

    private var background: Color {
        switch kind {
        case .filled: theme.primary
        case .tonal, .iconTonal, .fabExtended: theme.primaryContainer
        case .outlined, .text, .icon: .clear
        }
    }

    private var foreground: Color {
        switch kind {
        case .filled: theme.onPrimary
        case .tonal, .iconTonal, .fabExtended: theme.onPrimaryContainer
        case .outlined, .text: theme.primary
        case .icon: theme.onSurfaceVariant
        }
    }

    @ViewBuilder
    private var stateLayer: some View {
        let opacity = configuration.isPressed ? 0.12 : (isHovering && isEnabled ? 0.08 : 0)
        shape.fill(foreground.opacity(opacity))
            .allowsHitTesting(false)
    }
}

private struct VoqoraButtonLabelStyle: LabelStyle {
    let spacing: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}

extension ButtonStyle where Self == VoqoraButtonStyle {
    static var voqoraFilled: VoqoraButtonStyle {
        VoqoraButtonStyle(kind: .filled)
    }

    static var voqoraTonal: VoqoraButtonStyle {
        VoqoraButtonStyle(kind: .tonal)
    }

    static var voqoraOutlined: VoqoraButtonStyle {
        VoqoraButtonStyle(kind: .outlined)
    }

    static var voqoraText: VoqoraButtonStyle {
        VoqoraButtonStyle(kind: .text)
    }

    static var voqoraIcon: VoqoraButtonStyle {
        VoqoraButtonStyle(kind: .icon)
    }

    static var voqoraIconTonal: VoqoraButtonStyle {
        VoqoraButtonStyle(kind: .iconTonal)
    }

    static var voqoraFab: VoqoraButtonStyle {
        VoqoraButtonStyle(kind: .fabExtended)
    }

    static var voqoraPrimary: VoqoraButtonStyle {
        voqoraFilled
    }

    static var voqoraSecondary: VoqoraButtonStyle {
        voqoraOutlined
    }
}
