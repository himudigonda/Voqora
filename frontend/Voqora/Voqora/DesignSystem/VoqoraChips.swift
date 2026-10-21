import SwiftUI

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    var systemImage: String?
    let action: () -> Void

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .transition(.scale.combined(with: .opacity))
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                }
                Text(title)
                    .font(vm.font(.label))
            }
            .foregroundStyle(isSelected ? theme.onPrimaryContainer : theme.onSurfaceVariant)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .background(isSelected ? theme.secondaryContainer : theme.onSurface.opacity(isHovering ? 0.06 : 0), in: Capsule())
            .overlay {
                if !isSelected {
                    Capsule().strokeBorder(theme.outlineVariant, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.selection, value: isSelected)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct AssistChip: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.primary)
                }
                Text(title)
                    .font(vm.font(.label))
                    .foregroundStyle(theme.onSurface)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .background(theme.onSurface.opacity(isHovering ? 0.06 : 0), in: Capsule())
            .overlay(Capsule().strokeBorder(theme.outlineVariant, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.hover, value: isHovering)
        .onHover { isHovering = $0 }
    }
}
