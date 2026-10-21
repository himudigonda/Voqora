import SwiftUI

struct AudiobookshelfSettingsView: View {
    @EnvironmentObject var shelf: AudiobookshelfSettingsStore
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @State private var tokenDraft = ""
    @State private var replacingToken = false
    @State private var confirmingDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            connectionSection
            destinationSection
        }
        .task {
            if shelf.isConfigured, shelf.libraries.isEmpty {
                await shelf.testConnection()
            }
        }
        .confirmationDialog("Disconnect Audiobookshelf?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                tokenDraft = ""
                replacingToken = false
                shelf.disconnect()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Voqora removes the server address and deletes the token from your Keychain.")
        }
    }

    private var connectionSection: some View {
        SettingsSection(
            title: "Audiobookshelf",
            footer: "Send finished audiobooks to your Audiobookshelf server from a book's Export menu. " +
                "Create an API key in Audiobookshelf under Settings, then API Keys. The account needs permission to upload."
        ) {
            SettingsValueRow(title: "Server", systemImage: "server.rack") {
                TextField("Server", text: $shelf.serverText, prompt: Text("https://abs.example.com"))
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .settingsField(width: 320)
                    .onSubmit(test)
                    .accessibilityLabel("Audiobookshelf server address")
            }
            serverMessage
            tokenRow
            tokenMessage
            SettingsRowShell(title: "Connection", detail: "Check that Voqora can reach your server.", systemImage: "bolt.horizontal.circle") {
                HStack(spacing: 8) {
                    connectionStatus
                    Button(action: test) {
                        Label("Test Connection", systemImage: "bolt.horizontal.circle")
                    }
                    .buttonStyle(.voqoraTonal)
                    .disabled(shelf.connection == .testing || shelf.address.url == nil || !shelf.hasToken || shelf.needsTokenForAddress)
                    if shelf.hasToken || !shelf.serverText.isEmpty {
                        Button("Disconnect…") { confirmingDisconnect = true }
                            .buttonStyle(.voqoraDangerOutlined)
                    }
                }
            }
            failureMessage
        }
    }

    @ViewBuilder
    private var serverMessage: some View {
        if !shelf.serverText.trimmingCharacters(in: .whitespaces).isEmpty {
            if let error = shelf.address.error {
                SettingsNoticeRow(text: error, kind: .danger)
            } else if let warning = shelf.address.warning {
                SettingsNoticeRow(text: warning, kind: .warning)
            }
        }
    }

    private var tokenRow: some View {
        SettingsValueRow(title: "API Token", systemImage: "key") {
            if shelf.hasToken, !replacingToken, !shelf.needsTokenForAddress {
                HStack(spacing: 8) {
                    StatusChip(text: "Saved in your Keychain", kind: .success, systemImage: "lock.fill")
                    Button("Replace…") { replacingToken = true }
                        .buttonStyle(.voqoraTonal)
                        .accessibilityLabel("Replace API token")
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("API Token", text: $tokenDraft, prompt: Text("Paste token"))
                        .labelsHidden()
                        .settingsField(width: 240)
                        .onSubmit(saveToken)
                        .accessibilityLabel("Audiobookshelf API token")
                    Button("Save", action: saveToken)
                        .buttonStyle(.voqoraFilled)
                        .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if replacingToken {
                        Button("Cancel") {
                            tokenDraft = ""
                            replacingToken = false
                        }
                        .buttonStyle(.voqoraText)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var tokenMessage: some View {
        if let tokenError = shelf.tokenError {
            SettingsNoticeRow(text: tokenError, kind: .danger)
        } else if shelf.needsTokenForAddress {
            SettingsNoticeRow(text: AudiobookshelfSettingsStore.tokenForNewServerMessage, kind: .warning)
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch shelf.connection {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting…")
                    .font(vm.font(.label))
                    .foregroundStyle(theme.onSurfaceVariant)
            }
        case .connected:
            StatusChip(text: "Connected", kind: .success, systemImage: "checkmark.circle.fill")
        case .failed:
            StatusChip(text: "Failed", kind: .danger, systemImage: "exclamationmark.triangle.fill")
        }
    }

    @ViewBuilder
    private var failureMessage: some View {
        if case let .failed(message) = shelf.connection {
            SettingsNoticeRow(text: message, kind: .danger)
        }
    }

    @ViewBuilder
    private var destinationSection: some View {
        if !shelf.bookLibraries.isEmpty {
            SettingsSection(title: "Upload destination", footer: emptyFolderMessage) {
                SettingsPickerRow(
                    title: "Library",
                    systemImage: "books.vertical",
                    valueLabel: shelf.selectedLibrary?.name ?? "Choose…"
                ) {
                    Picker("Library", selection: Binding(
                        get: { shelf.libraryID ?? "" },
                        set: { shelf.selectLibrary($0) }
                    )) {
                        ForEach(shelf.bookLibraries) { library in
                            Text(library.name).tag(library.id)
                        }
                    }
                    .pickerStyle(.inline)
                }
                if let library = shelf.selectedLibrary, library.folders.count > 1 {
                    SettingsPickerRow(
                        title: "Folder",
                        systemImage: "folder",
                        valueLabel: library.folders.first { $0.id == shelf.folderID }?.displayName ?? "Choose…"
                    ) {
                        Picker("Folder", selection: Binding(
                            get: { shelf.folderID ?? "" },
                            set: { shelf.selectFolder($0) }
                        )) {
                            ForEach(library.folders) { folder in
                                Text(folder.displayName).tag(folder.id)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                }
            }
        } else if let libraryName = shelf.libraryName, shelf.isConfigured {
            SettingsSection(title: "Upload destination", footer: "Uploads go to the \(libraryName) library.") {
                SettingsValueRow(title: "Library", systemImage: "books.vertical") {
                    SettingsTextValue(text: libraryName)
                }
            }
        }
    }

    private var emptyFolderMessage: String? {
        shelf.selectedLibrary?.folders.isEmpty == true ? "This library has no folders, so Voqora can't upload to it." : nil
    }

    private func saveToken() {
        guard shelf.saveToken(tokenDraft) else { return }
        tokenDraft = ""
        replacingToken = false
        test()
    }

    private func test() {
        Task { await shelf.testConnection() }
    }
}
