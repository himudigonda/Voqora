import SwiftUI

struct ProviderConnectForm: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let provider: LLMProvider
    let backTitle: String
    var cleaningCount: (LLMProvider) -> Int = { _ in 0 }
    let onBack: () -> Void
    let onFinished: () -> Void

    @State private var apiKey = ""
    @State private var model = ""
    @State private var serverURL = ""
    @State private var models: [String] = []
    @State private var checking = false
    @State private var errorMessage: String?
    @State private var useForAudiobooks = false
    @State private var confirmingRemoval: LLMProvider?

    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    private var isEditing: Bool {
        providers.isConnected(provider)
    }

    private var othersConnected: Bool {
        providers.connectedProviders.contains { $0 != provider }
    }

    private var offersUseForAudiobooks: Bool {
        othersConnected && providers.activeProvider != provider
    }

    private var firstProviderNotice: String? {
        othersConnected || providers.activeProvider == provider ? nil : "Audiobooks will use \(provider.displayName)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                if provider.acceptsKey {
                    field(provider.requiresKey ? "API Key" : "API Key (Optional)") {
                        SecureField(provider.keyPlaceholder, text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(vm.font(.rowTitle).monospaced())
                    }
                }
                if provider.acceptsServerURL {
                    field("Server URL") {
                        TextField(provider.defaultServerURL.isEmpty ? "https://example.com/v1" : provider.defaultServerURL, text: $serverURL)
                            .textFieldStyle(.roundedBorder)
                            .font(vm.font(.rowTitle).monospaced())
                    }
                }
                field("Model") {
                    HStack(spacing: 8) {
                        TextField(modelPlaceholder, text: $model)
                            .textFieldStyle(.roundedBorder)
                            .font(vm.font(.rowTitle).monospaced())
                        if !models.isEmpty {
                            Menu {
                                ForEach(models, id: \.self) { name in
                                    Button(name) { model = name }
                                }
                            } label: {
                                Text("Choose")
                            }
                            .fixedSize()
                        } else if provider.acceptsServerURL {
                            Button("Find Models") { Task { await check(saving: false) } }
                                .disabled(checking)
                        }
                    }
                }
                if let url = provider.keyPageURL {
                    Link(provider.keyPageTitle, destination: url)
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(accentColor)
                }
                Label(provider.dataNotice, systemImage: provider.isLocal ? "lock.fill" : "arrow.up.forward.circle")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
                if offersUseForAudiobooks {
                    Toggle("Use for audiobooks", isOn: $useForAudiobooks)
                        .toggleStyle(.checkbox)
                        .font(vm.font(.rowTitle))
                } else if let firstProviderNotice {
                    Label(firstProviderNotice, systemImage: "books.vertical")
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.textSecondary)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .onAppear(perform: prefill)
        .providerRemovalDialog(target: $confirmingRemoval, cleaningCount: cleaningCount, onRemoved: onFinished)
    }

    private var header: some View {
        HStack(spacing: 16) {
            ProviderTile(provider: provider, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(isEditing ? "Edit \(provider.displayName)" : "Connect \(provider.displayName)")
                    .font(vm.appFont(size: 22, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                Text(provider.connectionSummary)
                    .font(vm.appFont(size: 13))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(backTitle, action: onBack)
                .buttonStyle(.voqoraSecondary)
            if isEditing {
                Button("Remove…", role: .destructive) {
                    confirmingRemoval = provider
                }
                .buttonStyle(.plain)
                .font(vm.font(.button))
                .foregroundStyle(Palette.danger)
            }
            Spacer()
            Button {
                Task { await check(saving: true) }
            } label: {
                HStack(spacing: 8) {
                    if checking {
                        ProgressView()
                            .controlSize(.small)
                            .tint(vm.onAccentColor(scheme: colorScheme, contrast: colorSchemeContrast))
                    }
                    Text(checking ? "Checking…" : (isEditing ? "Save" : "Connect"))
                }
                .frame(minWidth: 96)
            }
            .buttonStyle(.voqoraPrimary)
            .disabled(!canSubmit)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(vm.appFont(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            content()
        }
    }

    private var modelPlaceholder: String {
        provider.defaultModel.isEmpty ? "Choose a model" : provider.defaultModel
    }

    private var canSubmit: Bool {
        if checking {
            return false
        }
        if provider.requiresKey, trimmed(apiKey).isEmpty {
            return false
        }
        if provider == .custom, trimmed(serverURL).isEmpty {
            return false
        }
        return true
    }

    private var draft: LLMCredential {
        LLMCredential(
            provider: provider,
            apiKey: provider.acceptsKey ? trimmed(apiKey) : "",
            model: trimmed(model),
            serverURL: provider.acceptsServerURL ? trimmed(serverURL) : ""
        )
    }

    private func prefill() {
        let settings = providers.settings(for: provider)
        apiKey = providers.storedKey(for: provider)
        model = settings.model
        serverURL = settings.serverURL
        useForAudiobooks = providers.activeProvider == nil && othersConnected
        if provider.isLocal {
            Task { await check(saving: false) }
        }
    }

    private func check(saving: Bool) async {
        checking = true
        errorMessage = nil
        defer { checking = false }
        let result = await providers.verify(draft)
        if !result.models.isEmpty {
            models = result.models
        }
        if !result.verified, trimmed(model).isEmpty, let first = result.models.first {
            model = first
            if saving {
                errorMessage = provider.defaultModel.isEmpty
                    ? "Pick a model to continue."
                    : "Pick a model: \(provider.defaultModel) isn't available to this key."
            }
            return
        }
        guard saving else { return }
        guard result.verified else {
            errorMessage = result.error ?? "Voqora could not connect to \(provider.displayName)."
            return
        }
        guard providers.save(draft, makeActive: offersUseForAudiobooks && useForAudiobooks) else {
            errorMessage = "\(provider.displayName) accepted the key, but Voqora couldn't save it to your Keychain."
            return
        }
        onFinished()
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
