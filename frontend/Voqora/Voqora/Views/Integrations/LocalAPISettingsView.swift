import SwiftUI

struct LocalAPISettingsView: View {
    @EnvironmentObject var localAPI: LocalAPIController
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @State private var revealsKey = false
    @State private var confirmingRegenerate = false
    @FocusState private var portFocused: Bool

    private static let refreshIntervalNanoseconds: UInt64 = 5_000_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            apiSection
            connectionSection
            if localAPI.isEnabled, !localAPI.apiKey.isEmpty {
                snippetsSection
            }
        }
        .task(id: localAPI.isEnabled) {
            guard localAPI.isEnabled else { return }
            while !Task.isCancelled {
                await localAPI.refreshStatus()
                try? await Task.sleep(nanoseconds: Self.refreshIntervalNanoseconds)
            }
        }
        .onChange(of: portFocused) { _, focused in
            if !focused {
                localAPI.commitPort()
            }
        }
        .confirmationDialog("Create a new API key?", isPresented: $confirmingRegenerate, titleVisibility: .visible) {
            Button("Create New Key", role: .destructive) { localAPI.regenerateKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apps using the current key stop working until you give them the new one.")
        }
    }

    private var apiSection: some View {
        SettingsSection(title: "Local API") {
            SettingsSwitchRow(
                title: "Local API",
                detail: "Lets apps and AI tools on this Mac speak with Voqora's voices through an OpenAI-compatible endpoint and an MCP server.",
                systemImage: "network",
                isOn: Binding(get: { localAPI.isEnabled }, set: { localAPI.setEnabled($0) })
            )
            SettingsValueRow(title: "Status", systemImage: "waveform.path.ecg") {
                statusChip
            }
            if let keyError = localAPI.keyError {
                SettingsNoticeRow(text: keyError, kind: .danger)
            }
        }
    }

    private var connectionSection: some View {
        SettingsSection(title: "Connection", footer: connectionFooter) {
            SettingsValueRow(title: "Port", detail: "A number from 1024 to 65535. Press Return to apply.", systemImage: "number") {
                TextField("Port", text: $localAPI.portText, prompt: Text("1024–65535"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .settingsField(width: 120)
                    .focused($portFocused)
                    .onSubmit { localAPI.commitPort() }
                    .accessibilityLabel("Local API port")
                    .accessibilityHint("A number from 1024 to 65535. Press Return to apply.")
            }
            SettingsValueRow(title: "API Key", systemImage: "key") {
                keyValue
            }
            SettingsButtonRow(
                title: localAPI.apiKey.isEmpty ? "Create a key" : "Replace the key",
                detail: localAPI.apiKey.isEmpty ? "Clients need a key to connect." : "Apps using the current key stop working until you give them the new one.",
                systemImage: "arrow.triangle.2.circlepath",
                buttonTitle: localAPI.apiKey.isEmpty ? "Create Key" : "Regenerate…"
            ) {
                if localAPI.apiKey.isEmpty {
                    localAPI.regenerateKey()
                } else {
                    confirmingRegenerate = true
                }
            }
            if let portError = localAPI.portError {
                SettingsNoticeRow(text: portError, kind: .danger)
            }
        }
    }

    private var connectionFooter: String {
        var lines = [
            "Clients connect to \(LocalAPISnippets.baseURL(port: localAPI.port)). They send the API key as a Bearer token, stored in your Keychain.",
        ]
        if localAPI.isEnabled, !localAPI.apiKey.isEmpty {
            lines.append("Speech requested by these tools plays through Voqora with your current voice, unless the request names a voice. A new request replaces the one playing.")
        }
        return lines.joined(separator: " ")
    }

    @ViewBuilder
    private var statusChip: some View {
        let text = localAPI.phase.statusLine
        switch localAPI.phase {
        case .off:
            StatusChip(text: text, kind: .neutral, systemImage: "circle")
        case .waitingForEngine:
            StatusChip(text: text, kind: .neutral, systemImage: "hourglass")
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text)
                    .font(vm.font(.label))
                    .foregroundStyle(theme.onSurfaceVariant)
            }
        case .running:
            StatusChip(text: text, kind: .success, systemImage: "checkmark.circle.fill")
        case .failed:
            StatusChip(text: text, kind: .danger, systemImage: "exclamationmark.triangle.fill")
        }
    }

    @ViewBuilder
    private var keyValue: some View {
        if localAPI.apiKey.isEmpty {
            SettingsTextValue(text: "Created when you turn on the local API.")
        } else {
            HStack(spacing: 8) {
                Text(revealsKey ? localAPI.apiKey : LocalAPIKey.masked(localAPI.apiKey))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(theme.onSurface)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: 280, minHeight: 32)
                    .background(theme.surfaceContainerHighest, in: Capsule())
                    .accessibilityLabel("API key")
                    .accessibilityValue(revealsKey ? localAPI.apiKey : "Hidden")
                Button {
                    revealsKey.toggle()
                } label: {
                    Image(systemName: revealsKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.voqoraIcon)
                .help(revealsKey ? "Hide key" : "Show key")
                .accessibilityLabel(revealsKey ? "Hide API key" : "Show API key")
                CopyButton(accessibilityTitle: "API key", text: { localAPI.apiKey })
            }
        }
    }

    private var snippetsSection: some View {
        let port = localAPI.port
        let key = localAPI.apiKey
        let shown = revealsKey ? key : LocalAPIKey.masked(key)
        return SettingsSection(title: "Connect your tools") {
            CopyableSnippet(
                title: "OpenAI-compatible speech",
                caption: "Any OpenAI text-to-speech client works. Point its base URL at \(LocalAPISnippets.baseURL(port: port))/v1.",
                displayText: LocalAPISnippets.speechCurl(port: port, key: shown),
                copyText: LocalAPISnippets.speechCurl(port: port, key: key)
            )
            CopyableSnippet(
                title: "Claude Code",
                caption: "Run this once in Terminal to add Voqora as an MCP server.",
                displayText: LocalAPISnippets.claudeCode(port: port, key: shown),
                copyText: LocalAPISnippets.claudeCode(port: port, key: key)
            )
            CopyableSnippet(
                title: "Other MCP clients",
                caption: "Add this entry to the client's MCP configuration file.",
                displayText: LocalAPISnippets.mcpServersJSON(port: port, key: shown),
                copyText: LocalAPISnippets.mcpServersJSON(port: port, key: key)
            )
        }
    }
}
