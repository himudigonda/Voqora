import SwiftUI

private struct ProviderRemovalDialog: ViewModifier {
    @EnvironmentObject var providers: LLMProviderStore
    @Binding var target: LLMProvider?
    let cleaningCount: (LLMProvider) -> Int
    let onRemoved: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            target.map(ProviderRemovalNotice.title(for:)) ?? "Remove Provider?",
            isPresented: Binding(get: { target != nil }, set: {
                if !$0 {
                    target = nil
                }
            }),
            titleVisibility: .visible,
            presenting: target
        ) { provider in
            Button("Remove", role: .destructive) {
                providers.remove(provider)
                onRemoved()
            }
            Button("Cancel", role: .cancel) {}
        } message: { provider in
            Text(message(for: provider))
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

extension View {
    func providerRemovalDialog(
        target: Binding<LLMProvider?>,
        cleaningCount: @escaping (LLMProvider) -> Int = { _ in 0 },
        onRemoved: @escaping () -> Void = {}
    ) -> some View {
        modifier(ProviderRemovalDialog(target: target, cleaningCount: cleaningCount, onRemoved: onRemoved))
    }
}
