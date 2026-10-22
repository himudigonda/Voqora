import AppKit
import SwiftUI

struct ProviderConnectForm: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @Environment(\.voqoraTheme) private var theme

    let provider: LLMProvider
    var cleaningCount: (LLMProvider) -> Int = { _ in 0 }
    var onBack: (() -> Void)?
    let onClose: () -> Void
    let onFinished: () -> Void

    @State private var apiKey = ""
    @State private var model = ""
    @State private var serverURL = ""
    @State private var models: [String] = []
    @State private var checking = false
    @State private var errorMessage: String?
    @State private var useForAudiobooks = false
    @State private var confirmingRemoval = false

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
        Group {
            if confirmingRemoval {
                removalConfirmation
            } else {
                connectSheet
            }
        }
        .onAppear(perform: prefill)
    }

    private var connectSheet: some View {
        VoqoraSheet(
            title: isEditing ? "Edit \(provider.displayName)" : "Connect \(provider.displayName)",
            supporting: provider.connectionSummary,
            primaryTitle: checking ? "Checking…" : (isEditing ? "Save" : "Connect"),
            isPrimaryEnabled: canSubmit,
            width: 560,
            onPrimary: { Task { await check(saving: true) } },
            onClose: onClose
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.card) {
                if let onBack {
                    Button(action: onBack) {
                        Label("All providers", systemImage: "chevron.left")
                    }
                    .buttonStyle(.voqoraText)
                    .padding(.leading, -12)
                }
                HStack(spacing: 14) {
                    ProviderTile(provider: provider, size: 48)
                    notices
                }
                fields
                if checking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking connection…")
                            .voqoraFont(.bodySmall)
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                }
                if let errorMessage {
                    SettingsNoticeRow(text: errorMessage, kind: .danger)
                }
                if isEditing {
                    Button("Remove…") { confirmingRemoval = true }
                        .buttonStyle(.voqoraDangerOutlined)
                }
            }
        }
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(provider.dataNotice, systemImage: provider.isLocal ? "lock.fill" : "arrow.up.forward.circle")
            if !offersUseForAudiobooks, let firstProviderNotice {
                Label(firstProviderNotice, systemImage: "books.vertical")
            }
        }
        .voqoraFont(.bodySmall)
        .foregroundStyle(theme.onSurfaceVariant)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item + 4) {
            if provider.acceptsKey {
                field(provider.requiresKey ? "API Key" : "API Key (Optional)") {
                    SecureField("API Key", text: $apiKey, prompt: Text(provider.keyPlaceholder))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .settingsField()
                }
            }
            if provider.acceptsServerURL {
                field("Server URL") {
                    TextField(
                        "Server URL",
                        text: $serverURL,
                        prompt: Text(provider.defaultServerURL.isEmpty ? "https://example.com/v1" : provider.defaultServerURL)
                    )
                    .labelsHidden()
                    .font(.body.monospaced())
                    .settingsField()
                }
            }
            field("Model") {
                HStack(spacing: 8) {
                    TextField("Model", text: $model, prompt: Text(modelPlaceholder))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .settingsField()
                    if !models.isEmpty {
                        TonalMenu(valueLabel: "Choose") {
                            ForEach(models, id: \.self) { name in
                                Button(name) { model = name }
                            }
                        }
                    } else if provider.acceptsServerURL {
                        Button("Find Models") { Task { await check(saving: false) } }
                            .buttonStyle(.voqoraTonal)
                            .disabled(checking)
                    }
                }
            }
            if let url = provider.keyPageURL {
                AssistChip(title: provider.keyPageTitle, systemImage: "arrow.up.right.square") {
                    NSWorkspace.shared.open(url)
                }
            }
            if offersUseForAudiobooks {
                Toggle("Use for audiobooks", isOn: $useForAudiobooks)
                    .toggleStyle(.voqoraSwitch)
                    .voqoraFont(.body)
            }
        }
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .voqoraFont(.label)
                .foregroundStyle(theme.onSurfaceVariant)
            content()
        }
    }

    private var removalConfirmation: some View {
        VoqoraSheet(title: ProviderRemovalNotice.title(for: provider), width: 560, onClose: onClose) {
            VStack(alignment: .leading, spacing: Theme.Space.card) {
                Text(ProviderRemovalNotice.message(
                    provider: provider,
                    isActive: providers.activeProvider == provider,
                    cleaningCount: cleaningCount(provider),
                    remaining: providers.connectedProviders.filter { $0 != provider }
                ))
                .voqoraFont(.body)
                .foregroundStyle(theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.item) {
                    Spacer(minLength: 0)
                    Button("Cancel") { confirmingRemoval = false }
                        .buttonStyle(.voqoraText)
                        .keyboardShortcut(.defaultAction)
                    Button("Remove") {
                        providers.remove(provider)
                        onFinished()
                    }
                    .buttonStyle(.voqoraDangerFilled)
                }
            }
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
