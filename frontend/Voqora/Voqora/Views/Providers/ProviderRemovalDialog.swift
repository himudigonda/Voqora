import SwiftUI

private struct ProviderRemovalDialog: ViewModifier {
    @EnvironmentObject var providers: LLMProviderStore
    @EnvironmentObject var vm: DashboardViewModel
    @Binding var target: LLMProvider?
    let cleaningCount: (LLMProvider) -> Int
    let onRemoved: () -> Void

    func body(content: Content) -> some View {
        content.sheet(item: $target) { provider in
            RemovalSheet(
                title: ProviderRemovalNotice.title(for: provider),
                message: message(for: provider),
                remove: {
                    providers.remove(provider)
                    target = nil
                    onRemoved()
                },
                cancel: { target = nil }
            )
            .environmentObject(vm)
            .environmentObject(providers)
            .voqoraTheme()
        }
    }

    private func message(for provider: LLMProvider) -> String {
        ProviderRemovalNotice.message(
            provider: provider,
            isActive: providers.activeProvider == provider,
            cleaningCount: cleaningCount(provider),
            remaining: providers.connectedProviders.filter { $0 != provider }
        )
    }
}

private struct RemovalSheet: View {
    let title: String
    let message: String
    let remove: () -> Void
    let cancel: () -> Void

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        VoqoraSheet(title: title, width: 460, onClose: cancel) {
            VStack(alignment: .leading, spacing: Theme.Space.card) {
                Text(message)
                    .voqoraFont(.body)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.item) {
                    Spacer(minLength: 0)
                    Button("Cancel", action: cancel)
                        .buttonStyle(.voqoraText)
                        .keyboardShortcut(.defaultAction)
                    Button("Remove", action: remove)
                        .buttonStyle(.voqoraDangerFilled)
                }
            }
        }
    }
}

extension View {
    func providerRemovalDialog(
        target: Binding<LLMProvider?>,
        cleaningCount: @escaping (LLMProvider) -> Int = { _ in 0 },
        onRemoved: @escaping () -> Void = {}
    ) -> some View {
        modifier(ProviderRemovalDialog(target: target, cleaningCount: cleaningCount, onRemoved: onRemoved))
    }
}
