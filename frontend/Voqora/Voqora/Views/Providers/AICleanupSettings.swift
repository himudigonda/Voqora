import SwiftUI

struct AICleanupSettings: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @State private var sheet: ProviderSheet?
    @State private var removalTarget: LLMProvider?

    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if providers.connectedProviders.isEmpty {
                emptyState
            } else {
                audiobookHeader
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
                "Narration always runs on your Mac. When you turn on AI cleanup for a document, its text goes to the provider used for audiobooks. " +
                    "Local providers keep it on your Mac. Keys are stored in your Keychain."
            )
            .font(vm.font(.rowSubtitle))
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .add: AddProviderSheet(cleaningCount: bookVM.cleaningBookCount(using:))
                case let .edit(provider): AddProviderSheet(provider: provider, cleaningCount: bookVM.cleaningBookCount(using:))
                }
            }
            .environmentObject(vm)
            .environmentObject(providers)
        }
        .providerRemovalDialog(target: $removalTarget, cleaningCount: bookVM.cleaningBookCount(using:))
    }

    private var audiobookHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Used for audiobooks")
                .font(vm.font(.rowTitle).weight(.semibold))
            if providers.needsActiveChoice {
                Label("Choose which provider audiobooks use.", systemImage: "exclamationmark.circle.fill")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.warning)
            } else {
                Text("Cleanup for new and resumed audiobooks goes to the selected provider.")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
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
            Button {
                providers.use(provider)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: isInUse ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isInUse ? accentColor : Palette.textSecondary)
                        .frame(width: 18)
                    ProviderTile(provider: provider, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.displayName)
                            .font(vm.font(.rowTitle).weight(.semibold))
                            .foregroundStyle(Palette.textPrimary)
                        Text(detail(provider, settings))
                            .font(vm.font(.rowSubtitle).monospaced())
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(provider.displayName)
            .accessibilityValue(detail(provider, settings))
            .accessibilityHint("Use for audiobooks")
            .accessibilityAddTraits(isInUse ? .isSelected : [])
            Menu {
                Button("Edit…") { sheet = .edit(provider) }
                Button("Remove…", role: .destructive) { removalTarget = provider }
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
