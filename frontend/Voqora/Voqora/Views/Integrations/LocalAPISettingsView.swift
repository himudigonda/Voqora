import SwiftUI

struct LocalAPISettingsView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var localAPI: LocalAPIController
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var revealsKey = false
    @State private var confirmingRegenerate = false
    @FocusState private var portFocused: Bool

    private static let refreshIntervalNanoseconds: UInt64 = 5_000_000_000

    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: Binding(get: { localAPI.isEnabled }, set: { localAPI.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local API")
                        .font(vm.font(.rowTitle))
                    Text("Lets apps and AI tools on this Mac speak with Voqora's voices through an OpenAI-compatible endpoint and an MCP server.")
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, alignment: .leading)

            statusLine

            if let keyError = localAPI.keyError {
                Text(keyError)
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.danger)
            }

            Divider()
            portRow
            Divider()
            keyRow

            if localAPI.isEnabled, !localAPI.apiKey.isEmpty {
                Divider()
                snippets
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

    private var statusLine: some View {
        HStack(spacing: 6) {
            switch localAPI.phase {
            case .off:
                Image(systemName: "circle").foregroundStyle(Palette.textTertiary)
            case .waitingForEngine:
                Image(systemName: "hourglass").foregroundStyle(Palette.textSecondary)
            case .starting:
                ProgressView().controlSize(.small)
            case .running:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
            }
            Text(localAPI.phase.statusLine)
                .foregroundStyle(localAPI.phase.isFailure ? Palette.danger : Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(vm.appFont(size: 12, weight: .semibold))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Local API status: \(localAPI.phase.statusLine)")
    }

    private var portRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Port", systemImage: "number")
                    .font(vm.font(.rowTitle))
                Spacer()
                TextField("Port", text: $localAPI.portText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .font(vm.font(.rowTitle).monospacedDigit())
                    .frame(width: 90)
                    .focused($portFocused)
                    .onSubmit { localAPI.commitPort() }
                    .accessibilityLabel("Local API port")
                    .accessibilityHint("A number from 1024 to 65535. Press Return to apply.")
            }
            if let portError = localAPI.portError {
                Text(portError)
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.danger)
            } else {
                Text("Clients connect to \(LocalAPISnippets.baseURL(port: localAPI.port)).")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("API Key", systemImage: "key")
                    .font(vm.font(.rowTitle))
                Spacer(minLength: 12)
                if localAPI.apiKey.isEmpty {
                    Text("Created when you turn on the local API.")
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.textSecondary)
                } else {
                    Text(revealsKey ? localAPI.apiKey : LocalAPIKey.masked(localAPI.apiKey))
                        .font(vm.font(.rowSubtitle).monospaced())
                        .foregroundStyle(Palette.textPrimary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel("API key")
                        .accessibilityValue(revealsKey ? localAPI.apiKey : "Hidden")
                    Button {
                        revealsKey.toggle()
                    } label: {
                        Image(systemName: revealsKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(revealsKey ? "Hide key" : "Show key")
                    .accessibilityLabel(revealsKey ? "Hide API key" : "Show API key")
                    CopyButton(accessibilityTitle: "API key", text: { localAPI.apiKey })
                }
            }
            HStack {
                Text("Clients send this key as a Bearer token. It is stored in your Keychain.")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Button(localAPI.apiKey.isEmpty ? "Create Key" : "Regenerate…") {
                    if localAPI.apiKey.isEmpty {
                        localAPI.regenerateKey()
                    } else {
                        confirmingRegenerate = true
                    }
                }
                .buttonStyle(.borderless)
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(accentColor)
            }
        }
    }

    private var snippets: some View {
        let port = localAPI.port
        let key = localAPI.apiKey
        let shown = revealsKey ? key : LocalAPIKey.masked(key)
        return VStack(alignment: .leading, spacing: 18) {
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
            Text("Speech requested by these tools plays through Voqora with your current voice, unless the request names a voice. A new request replaces the one playing.")
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
