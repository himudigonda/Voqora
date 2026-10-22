import SwiftUI

struct FormSection<Content: View>: View {
    var step: Int?
    let title: String
    var supporting: String?
    @ViewBuilder var content: Content

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            HStack(spacing: Theme.Space.item) {
                if let step {
                    Text("\(step)")
                        .font(vm.font(.label))
                        .foregroundStyle(theme.onPrimary)
                        .frame(width: 28, height: 28)
                        .background(theme.primary, in: Circle())
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(vm.font(.title))
                        .foregroundStyle(theme.onSurface)
                        .accessibilityAddTraits(.isHeader)
                    if let supporting {
                        Text(supporting)
                            .font(vm.font(.bodySmall))
                            .foregroundStyle(theme.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            VoqoraCard {
                VStack(alignment: .leading, spacing: Theme.Space.item + 4) {
                    content
                }
            }
        }
    }
}

struct SummaryCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VoqoraCard(.elevated) {
            VStack(alignment: .leading, spacing: Theme.Space.item + 4) {
                content
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct FormColumns<Main: View, Side: View>: View {
    @ViewBuilder var main: Main
    @ViewBuilder var side: Side

    private static var sideWidth: CGFloat {
        320
    }

    private static var sideBySideMinWidth: CGFloat {
        880
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= Self.sideBySideMinWidth {
                sideBySide
            } else {
                stacked
            }
        }
    }

    private var sideBySide: some View {
        HStack(alignment: .top, spacing: Theme.Space.section) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    main
                }
                .padding(.leading, Theme.Space.gutter)
                .padding(.bottom, Theme.Space.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView(showsIndicators: false) {
                side
                    .padding(.bottom, Theme.Space.gutter)
            }
            .frame(width: Self.sideWidth)
            .padding(.trailing, Theme.Space.gutter)
        }
    }

    private var stacked: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                main
                side
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.bottom, Theme.Space.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum StatusChipKind {
    case neutral
    case info
    case success
    case warning
    case danger
}

struct StatusChip: View {
    let text: String
    var kind: StatusChipKind = .neutral
    var systemImage: String?

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(vm.font(.labelSmall))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .frame(minHeight: 22)
        .background(tint.opacity(0.14), in: Capsule())
    }

    private var tint: Color {
        switch kind {
        case .neutral: theme.onSurfaceVariant
        case .info: theme.onPrimaryContainer
        case .success: theme.success
        case .warning: theme.warning
        case .danger: theme.danger
        }
    }
}

struct DropZone: View {
    let title: String
    var supporting: String?
    var systemImage = "arrow.down.doc"
    var buttonTitle: String?
    var isTargeted = false
    var action: (() -> Void)?

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        VStack(spacing: Theme.Space.item) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(theme.onPrimaryContainer)
                .frame(width: 60, height: 60)
                .background(theme.primaryContainer.opacity(isTargeted ? 1 : 0.65), in: Circle())
                .accessibilityHidden(true)
            Text(title)
                .font(vm.font(.titleSmall))
                .foregroundStyle(theme.onSurface)
            if let supporting {
                Text(supporting)
                    .font(vm.font(.bodySmall))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.voqoraTonal)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.section)
        .padding(.horizontal, Theme.Space.card)
        .background(
            isTargeted ? theme.secondaryContainer : theme.surfaceContainerLow,
            in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous)
                .strokeBorder(isTargeted ? theme.primary : theme.outline.opacity(0.7), style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 5]))
        )
        .animation(Theme.Motion.selection, value: isTargeted)
    }
}

struct OptionCard: View {
    let title: String
    var supporting: String?
    let systemImage: String
    var isSelected = false
    var badge: String?
    let action: () -> Void

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                HStack(alignment: .top) {
                    Image(systemName: systemImage)
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(theme.onPrimaryContainer)
                        .frame(width: 52, height: 52)
                        .background(theme.primaryContainer.opacity(0.65), in: Circle())
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                    if let badge {
                        StatusChip(text: badge, kind: .info)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(vm.font(.title))
                        .foregroundStyle(theme.onSurface)
                    if let supporting {
                        Text(supporting)
                            .font(vm.font(.body))
                            .foregroundStyle(theme.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Theme.Space.card)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous)
                        .strokeBorder(theme.primary, lineWidth: 2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.hover, value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        isSelected ? theme.secondaryContainer : (isHovering ? theme.surfaceContainerHigh : theme.surfaceContainer)
    }
}
