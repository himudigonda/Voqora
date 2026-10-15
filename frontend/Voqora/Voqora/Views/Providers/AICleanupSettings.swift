import SwiftUI

struct AICleanupSettings: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @State private var sheet: ProviderSheet?

    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if providers.connectedProviders.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(providers.connectedProviders.enumerated()), id: \.element) { index, provider in
                        if index > 0 {
                            Divider().padding(.vertical, 10)
                        }
                        row(provider)
                    }
                }
                Divider()
                HStack {
                    Button {
                        sheet = .add
                    } label: {
                        Label("Add Provider", systemImage: "plus")
                    }
                    .buttonStyle(.voqoraSecondary)
                    Spacer()
                }
            }
            Text(
                "Narration always runs on your Mac. When you turn on AI cleanup for a document, its text goes to the provider in use. " +
                    "Local providers keep it on your Mac. Keys are stored in your Keychain."
            )
            .font(vm.font(.rowSubtitle))
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .add: AddProviderSheet()
                case let .edit(provider): AddProviderSheet(provider: provider)
                }
            }
            .environmentObject(vm)
            .environmentObject(providers)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 22))
                .foregroundStyle(accentColor)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("No provider connected")
                    .font(vm.font(.rowTitle).weight(.semibold))
                Text("Connect one to clean up messy documents and read scanned PDFs.")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Button("Add Provider…") { sheet = .add }
                .buttonStyle(.voqoraPrimary)
        }
    }

    private func row(_ provider: LLMProvider) -> some View {
        let isInUse = providers.activeProvider == provider
        let settings = providers.settings(for: provider)
        return HStack(spacing: 14) {
            ProviderTile(provider: provider, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(provider.displayName)
                        .font(vm.font(.rowTitle).weight(.semibold))
                    if isInUse {
                        Text("IN USE")
                            .font(vm.font(.chip))
                            .kerning(0.6)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(accentColor)
                    }
                }
                Text(detail(provider, settings))
                    .font(vm.font(.rowSubtitle).monospaced())
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !isInUse {
                Button("Use") { providers.use(provider) }
                    .buttonStyle(.borderless)
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(accentColor)
            }
            Menu {
                Button("Edit…") { sheet = .edit(provider) }
                Button("Remove", role: .destructive) { providers.remove(provider) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(provider.displayName) options")
        }
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
