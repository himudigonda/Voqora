import SwiftUI

struct ProviderPickerGrid: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var compact = false
    let onSelect: (LLMProvider) -> Void

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: compact ? 10 : 14), GridItem(.flexible(), spacing: compact ? 10 : 14)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: compact ? 10 : 14) {
            ForEach(LLMProvider.allCases) { provider in
                ProviderCard(
                    provider: provider,
                    isConnected: providers.isConnected(provider),
                    isInUse: providers.activeProvider == provider,
                    compact: compact,
                    accentColor: vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
                ) {
                    onSelect(provider)
                }
            }
        }
    }
}

private struct ProviderCard: View {
    @EnvironmentObject var vm: DashboardViewModel

    let provider: LLMProvider
    let isConnected: Bool
    let isInUse: Bool
    let compact: Bool
    let accentColor: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 12 : 16) {
                ProviderTile(provider: provider, size: compact ? 34 : 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(vm.appFont(size: compact ? 13 : 15, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text(subtitle)
                        .font(vm.appFont(size: compact ? 11 : 12))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 10 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous)
                    .strokeBorder(accentColor.opacity(hovering ? 0.55 : 0), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DesignTokens.Animation.quick, value: hovering)
        .accessibilityLabel(provider.displayName)
        .accessibilityValue(isConnected ? "Connected" : provider.connectionSummary)
    }

    private var subtitle: String {
        if isInUse {
            return "In use for AI cleanup"
        }
        return isConnected ? "Connected" : provider.connectionSummary
    }

    @ViewBuilder
    private var trailing: some View {
        if isConnected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: compact ? 15 : 17))
                .foregroundStyle(Palette.success)
        } else if provider == .custom {
            Image(systemName: "plus")
                .font(.system(size: compact ? 14 : 17, weight: .medium))
                .foregroundStyle(accentColor)
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: compact ? 12 : 14, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
        }
    }
}
