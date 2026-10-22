import SwiftUI

struct CategoryRailItem: Identifiable {
    let key: String
    let title: String
    let symbol: String

    var id: String {
        key
    }
}

struct CategoryRailHost<Content: View>: View {
    let title: String
    let items: [CategoryRailItem]
    let selectedKey: String
    @ViewBuilder var content: Content

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle()
                .fill(theme.outlineVariant)
                .frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rail: some View {
        ScrollView {
            VStack(spacing: 2) {
                Text(title)
                    .font(vm.font(.titleSmall))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
                ForEach(items) { item in
                    CategoryRailRow(item: item, isSelected: item.key == selectedKey) {
                        vm.selectedTab = item.key
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 28)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .clipped()
    }
}

private struct CategoryRailRow: View {
    let item: CategoryRailItem
    let isSelected: Bool
    let action: () -> Void

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .symbolVariant(isSelected ? .fill : .none)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(item.title)
                    .font(vm.font(isSelected ? .label : .body))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? theme.onPrimaryContainer : theme.onSurfaceVariant)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.selection, value: isSelected)
        .animation(Theme.Motion.hover, value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected {
            return theme.primaryContainer
        }
        return isHovering ? theme.onSurface.opacity(0.06) : .clear
    }
}
