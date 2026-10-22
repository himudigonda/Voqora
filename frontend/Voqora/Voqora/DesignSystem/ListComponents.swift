import SwiftUI

struct ListGroup<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        VStack(spacing: Theme.Space.listGap) {
            content
        }
        .padding(Theme.Space.listGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceContainerLow, in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
    }
}

struct ListItemIcon: View {
    let systemImage: String
    var tint: Color?

    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(tint ?? theme.onPrimaryContainer)
            .frame(width: 40, height: 40)
            .background(theme.primaryContainer.opacity(0.65), in: Circle())
            .accessibilityHidden(true)
    }
}

struct ListItemRow<Leading: View, Trailing: View>: View {
    let title: String
    var supporting: String?
    let leading: Leading
    let trailing: Trailing

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        HStack(spacing: 16) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(vm.font(.body))
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                if let supporting {
                    Text(supporting)
                        .font(vm.font(.bodySmall))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: supporting == nil ? 56 : 72)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ListItem<Leading: View, Trailing: View>: View {
    let title: String
    var supporting: String?
    var isSelected = false
    var action: (() -> Void)?
    let leading: Leading
    let trailing: Trailing

    @Environment(\.voqoraTheme) private var theme
    @State private var isHovering = false

    init(
        title: String,
        supporting: String? = nil,
        isSelected: Bool = false,
        action: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.supporting = supporting
        self.isSelected = isSelected
        self.action = action
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) { row }
                    .buttonStyle(.plain)
            } else {
                row
            }
        }
        .background(background, in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
        .animation(Theme.Motion.hover, value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var row: some View {
        ListItemRow(title: title, supporting: supporting, leading: leading, trailing: trailing)
    }

    private var background: Color {
        if isSelected {
            return theme.secondaryContainer
        }
        return isHovering && action != nil ? theme.surfaceContainerHigh : theme.surfaceContainer
    }
}

extension ListItem where Leading == ListItemIcon {
    init(
        title: String,
        supporting: String? = nil,
        systemImage: String,
        isSelected: Bool = false,
        action: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            title: title,
            supporting: supporting,
            isSelected: isSelected,
            action: action,
            leading: { ListItemIcon(systemImage: systemImage) },
            trailing: trailing
        )
    }
}

extension ListItem where Leading == ListItemIcon, Trailing == EmptyView {
    init(
        title: String,
        supporting: String? = nil,
        systemImage: String,
        isSelected: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.init(title: title, supporting: supporting, systemImage: systemImage, isSelected: isSelected, action: action, trailing: { EmptyView() })
    }
}

extension ListItem where Trailing == EmptyView {
    init(
        title: String,
        supporting: String? = nil,
        isSelected: Bool = false,
        action: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading
    ) {
        self.init(title: title, supporting: supporting, isSelected: isSelected, action: action, leading: leading, trailing: { EmptyView() })
    }
}
