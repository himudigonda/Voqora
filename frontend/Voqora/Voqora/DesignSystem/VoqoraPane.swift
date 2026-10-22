import AppKit
import SwiftUI

struct PaneSectionHeader: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    let title: String

    var body: some View {
        Text(title)
            .font(vm.font(.titleSmall))
            .foregroundStyle(theme.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

struct PaneSection<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            if let title {
                PaneSectionHeader(title: title)
            }
            content
        }
    }
}

struct PaneRow<Leading: View, Label: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var leading: Leading
    @ViewBuilder var label: Label

    @Environment(\.voqoraTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Layout.rowIconGap) {
                leading
                label
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Layout.rowInsetHorizontal)
            .padding(.vertical, DesignTokens.Layout.rowInsetVertical)
            .frame(minHeight: 40)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? theme.onPrimaryContainer : theme.onSurface)
        .background(background, in: Capsule())
        .animation(Theme.Motion.selection, value: isSelected)
        .animation(Theme.Motion.hover, value: isHovering)
        .onHover { isHovering = $0 }
    }

    private var background: Color {
        if isSelected {
            return theme.primaryContainer
        }
        return isHovering ? theme.onSurface.opacity(0.06) : .clear
    }
}
