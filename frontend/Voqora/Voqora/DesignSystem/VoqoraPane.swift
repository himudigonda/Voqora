import AppKit
import SwiftUI

struct PaneSectionHeader: View {
    @EnvironmentObject var vm: DashboardViewModel
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(vm.font(.sectionHeader))
            .kerning(0.6)
            .foregroundStyle(Palette.textTertiary)
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
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
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

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var isHovering = false

    private var ramp: AccentRamp {
        Palette.accentRamp(
            for: vm.accentColorID,
            appearance: colorScheme,
            increaseContrast: colorSchemeContrast == .increased
        )
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Layout.rowIconGap) {
                leading
                label
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Layout.rowInsetHorizontal)
            .padding(.vertical, DesignTokens.Layout.rowInsetVertical)
            .frame(minHeight: DesignTokens.Layout.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color(ramp.strong) : Palette.textPrimary)
        .background(background, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
        .animation(DesignTokens.Animation.quick, value: isSelected)
        .animation(DesignTokens.Animation.quick, value: isHovering)
        .onHover { isHovering = $0 }
    }

    private var background: Color {
        if isSelected {
            return Color(ramp.muted)
        }
        if isHovering {
            return Color(ramp.subtle)
        }
        return .clear
    }
}
