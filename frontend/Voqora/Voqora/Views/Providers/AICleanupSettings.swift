import SwiftUI

struct AICleanupSettings: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @Environment(\.voqoraTheme) private var theme

    @Binding var sheet: ProviderSheet?
    @Binding var removalTarget: LLMProvider?

    private var activeSelection: Binding<LLMProvider?> {
        Binding(
            get: { providers.activeProvider },
            set: { provider in
                if let provider {
                    providers.use(provider)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            if providers.connectedProviders.isEmpty {
                emptyState
            } else {
                connectedSection
                audiobookSection
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connected providers")
                .voqoraFont(.titleSmall)
                .foregroundStyle(theme.primary)
                .padding(.horizontal, 4)
            VoqoraCard {
                EmptyStateView(
                    symbol: "sparkles",
                    title: "No provider connected",
                    message: "Connect one to clean up messy documents and read scanned PDFs. Narration always runs on your Mac, and keys are stored in your Keychain.",
                    action: EmptyStateAction(title: "Add Provider") { sheet = .add }
                )
            }
        }
    }

    private var connectedSection: some View {
        SettingsSection(
            title: "Connected providers",
            footer: "Narration always runs on your Mac. When you turn on AI cleanup for a document, its text goes to the provider used for audiobooks. " +
                "Local providers keep it on your Mac. Keys are stored in your Keychain."
        ) {
            ForEach(providers.connectedProviders) { provider in
                row(provider)
            }
        }
    }

    private var audiobookSection: some View {
        SettingsSection(title: "Audiobooks") {
            SettingsPickerRow(
                title: "Used for audiobooks",
                detail: "Cleanup for new and resumed audiobooks goes to this provider.",
                systemImage: "books.vertical",
                valueLabel: providers.activeProvider?.displayName ?? "Choose…"
            ) {
                Picker("Used for Audiobooks", selection: activeSelection) {
                    if providers.activeProvider == nil {
                        Text("Choose…").tag(LLMProvider?.none)
                    }
                    ForEach(providers.connectedProviders) { provider in
                        Text(provider.displayName).tag(LLMProvider?.some(provider))
                    }
                }
                .pickerStyle(.inline)
            }
            if providers.needsActiveChoice {
                SettingsNoticeRow(text: "Choose which provider audiobooks use.", kind: .warning)
            }
        }
    }

    private func row(_ provider: LLMProvider) -> some View {
        let isInUse = providers.activeProvider == provider
        let settings = providers.settings(for: provider)
        return ListItem(
            title: provider.displayName,
            supporting: detail(provider, settings),
            isSelected: false,
            leading: { ProviderTile(provider: provider, size: 40) },
            trailing: {
                HStack(spacing: 8) {
                    if isInUse {
                        StatusChip(text: "Used for Audiobooks", kind: .info, systemImage: "checkmark")
                    }
                    Menu {
                        Button("Use for Audiobooks") { providers.use(provider) }
                            .disabled(isInUse)
                        Button("Edit…") { sheet = .edit(provider) }
                        Divider()
                        Button("Remove…", role: .destructive) { removalTarget = provider }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.voqoraIcon)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("\(provider.displayName) options")
                }
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isInUse ? .isSelected : [])
    }

    private func detail(_ provider: LLMProvider, _ settings: LLMProviderSettings) -> String {
        let model = settings.model.isEmpty ? provider.defaultModel : settings.model
        if provider.acceptsServerURL, !settings.serverURL.isEmpty {
            return "\(model) · \(settings.serverURL)"
        }
        return model
    }
}

enum ProviderSheet: Identifiable, Hashable {
    case add
    case edit(LLMProvider)

    var id: String {
        switch self {
        case .add: "add"
        case let .edit(provider): provider.rawValue
        }
    }
}
