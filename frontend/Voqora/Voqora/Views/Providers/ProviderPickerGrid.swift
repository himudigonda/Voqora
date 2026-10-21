import SwiftUI

struct ProviderPickerGrid: View {
    @EnvironmentObject var providers: LLMProviderStore

    var compact = false
    let onSelect: (LLMProvider) -> Void

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: Theme.Space.item), GridItem(.flexible(), spacing: Theme.Space.item)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: Theme.Space.item) {
            ForEach(LLMProvider.allCases) { provider in
                ProviderCard(
                    provider: provider,
                    isConnected: providers.isConnected(provider),
                    isInUse: providers.activeProvider == provider,
                    compact: compact
                ) {
                    onSelect(provider)
                }
            }
        }
    }
}

private struct ProviderCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    let provider: LLMProvider
    let isConnected: Bool
    let isInUse: Bool
    let compact: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ProviderTile(provider: provider, size: compact ? 36 : 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .voqoraFont(.titleSmall)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    Text(subtitle)
                        .voqoraFont(.labelSmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, compact ? 10 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? theme.surfaceContainerHigh : theme.surfaceContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous)
                    .strokeBorder(theme.primary, lineWidth: isConnected ? 1.5 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
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
                .font(.system(size: 17))
                .foregroundStyle(theme.success)
        } else if provider == .custom {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.primary)
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.onSurfaceMuted)
        }
    }
}
