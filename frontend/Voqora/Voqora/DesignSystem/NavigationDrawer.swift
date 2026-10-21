import SwiftUI

struct NavDrawerItem: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var badge: Int?
    var indent: CGFloat = 0
    let action: () -> Void

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .symbolVariant(isSelected ? .fill : .none)
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(title)
                    .font(vm.font(isSelected ? .titleSmall : .body))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let badge, badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(vm.font(.labelSmall))
                        .monospacedDigit()
                        .foregroundStyle(theme.onPrimary)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(theme.primary, in: Capsule())
                        .accessibilityLabel("\(badge) unread")
                }
            }
            .foregroundStyle(isSelected ? theme.onPrimaryContainer : theme.onSurfaceVariant)
            .padding(.leading, 16 + indent)
            .padding(.trailing, 16)
            .frame(height: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.selection, value: isSelected)
        .animation(Theme.Motion.hover, value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected {
            return theme.primaryContainer
        }
        return isHovering ? theme.onSurface.opacity(0.06) : .clear
    }
}

struct NavDrawerGroup<Content: View>: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    @ViewBuilder var content: Content

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @AppStorage private var isExpanded: Bool
    @State private var isHovering = false

    init(
        title: String,
        systemImage: String,
        storageKey: String,
        isActive: Bool,
        defaultExpanded: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isActive = isActive
        self.content = content()
        _isExpanded = AppStorage(wrappedValue: defaultExpanded, storageKey)
    }

    var body: some View {
        VStack(spacing: 2) {
            header
            if isExpanded {
                VStack(spacing: 2) {
                    content
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onChange(of: isActive) { _, active in
            if active, !isExpanded {
                withAnimation(Theme.Motion.selection) { isExpanded = true }
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(Theme.Motion.selection) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(title)
                    .font(vm.font(isActive && !isExpanded ? .titleSmall : .body))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(isActive ? theme.onSurface : theme.onSurfaceVariant)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? theme.onSurface.opacity(0.06) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.hover, value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}
