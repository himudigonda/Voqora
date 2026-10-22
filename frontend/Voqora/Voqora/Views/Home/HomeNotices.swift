import SwiftUI

struct HomeNotices: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var permissions: PermissionsService

    var body: some View {
        if !vm.isBackendOnline || !permissions.accessibilityGranted {
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                EngineStatusBanner()
                if !permissions.accessibilityGranted {
                    AccessibilityPermissionCard()
                }
            }
        }
    }
}

private struct EngineStatusBanner: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        if !vm.isBackendOnline {
            HStack(spacing: Theme.Space.item) {
                if vm.isBackendInitializing {
                    ProgressView().controlSize(.small)
                    Text("Starting speech engine…")
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.warning)
                        .accessibilityHidden(true)
                    Text(vm.backendRecoveryMessage ?? "Speech engine unavailable. Retrying…")
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .font(vm.font(.label))
            .foregroundStyle(theme.onSurface)
            .padding(.horizontal, Theme.Space.card)
            .padding(.vertical, Theme.Space.item)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                vm.isBackendInitializing ? theme.primaryContainer.opacity(0.55) : theme.warning.opacity(0.14),
                in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous)
            )
            .accessibilityElement(children: .combine)
        }
    }
}

private struct AccessibilityPermissionCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var permissions: PermissionsService
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        VoqoraCard {
            HStack(spacing: Theme.Space.card) {
                ListItemIcon(systemImage: "hand.raised.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow Accessibility")
                        .font(vm.font(.titleSmall))
                        .foregroundStyle(theme.onSurface)
                    Text("Voqora needs it to read the text you select in other apps.")
                        .font(vm.font(.bodySmall))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.item)
                Button("Allow Accessibility") {
                    permissions.requestAccessibility()
                }
                .buttonStyle(.voqoraFilled)
            }
        }
    }
}
