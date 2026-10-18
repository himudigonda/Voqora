import SwiftUI

struct AudiobookshelfSettingsView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var shelf: AudiobookshelfSettingsStore
    @State private var tokenDraft = ""
    @State private var replacingToken = false
    @State private var confirmingDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Audiobookshelf")
                    .font(vm.font(.rowTitle))
                Text("Send finished audiobooks to your Audiobookshelf server from a book's Export menu.")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
            }

            serverRow
            tokenRow
            actionRow
            connectionStatus
            libraryPicker
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

    private var serverRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Server", systemImage: "server.rack")
                    .font(vm.font(.rowTitle))
                Spacer(minLength: 12)
                TextField("https://abs.example.com", text: $shelf.serverText)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)
                    .disableAutocorrection(true)
                    .font(vm.font(.rowTitle))
                    .frame(maxWidth: 320)
                    .onSubmit(test)
                    .accessibilityLabel("Audiobookshelf server address")
            }
            if !shelf.serverText.trimmingCharacters(in: .whitespaces).isEmpty {
                if let error = shelf.address.error {
                    Text(error)
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.danger)
                } else if let warning = shelf.address.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var tokenRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("API Token", systemImage: "key")
                    .font(vm.font(.rowTitle))
                Spacer(minLength: 12)
                if shelf.hasToken, !replacingToken {
                    Text("Saved in your Keychain")
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.textSecondary)
                    Button("Replace…") { replacingToken = true }
                        .buttonStyle(.voqoraSecondary)
                        .accessibilityLabel("Replace API token")
                } else {
                    SecureField("Paste token", text: $tokenDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        .onSubmit(saveToken)
                        .accessibilityLabel("Audiobookshelf API token")
                    Button("Save", action: saveToken)
                        .buttonStyle(.voqoraSecondary)
                        .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if replacingToken {
                        Button("Cancel") {
                            tokenDraft = ""
                            replacingToken = false
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            if let tokenError = shelf.tokenError {
                Text(tokenError)
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.danger)
            } else {
                Text("Create an API key in Audiobookshelf under Settings, then API Keys. The account needs permission to upload.")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionRow: some View {
        HStack {
            Button(action: test) {
                Label("Test Connection", systemImage: "bolt.horizontal.circle")
            }
            .buttonStyle(.voqoraPrimary)
            .disabled(shelf.connection == .testing || shelf.address.url == nil || !shelf.hasToken)
            Spacer()
            if shelf.hasToken || !shelf.serverText.isEmpty {
                Button("Disconnect…", role: .destructive) { confirmingDisconnect = true }
                    .buttonStyle(.borderless)
                    .font(vm.font(.rowSubtitle))
            }
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
            }
            .font(vm.appFont(size: 12, weight: .semibold))
            .foregroundStyle(Palette.textSecondary)
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(vm.appFont(size: 12, weight: .semibold))
                .foregroundStyle(Palette.success)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(vm.appFont(size: 12, weight: .semibold))
                .foregroundStyle(Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var libraryPicker: some View {
        if !shelf.bookLibraries.isEmpty {
            Divider()
            HStack {
                Label("Library", systemImage: "books.vertical")
                    .font(vm.font(.rowTitle))
                Spacer()
                Picker("Library", selection: Binding(
                    get: { shelf.libraryID ?? "" },
                    set: { shelf.selectLibrary($0) }
                )) {
                    ForEach(shelf.bookLibraries) { library in
                        Text(library.name).tag(library.id)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            if let library = shelf.selectedLibrary, library.folders.count > 1 {
                HStack {
                    Label("Folder", systemImage: "folder")
                        .font(vm.font(.rowTitle))
                    Spacer()
                    Picker("Folder", selection: Binding(
                        get: { shelf.folderID ?? "" },
                        set: { shelf.selectFolder($0) }
                    )) {
                        ForEach(library.folders) { folder in
                            Text(folder.displayName).tag(folder.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
            if shelf.selectedLibrary?.folders.isEmpty == true {
                Text("This library has no folders, so Voqora can't upload to it.")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.danger)
            }
        } else if let libraryName = shelf.libraryName, shelf.isConfigured {
            Text("Uploads go to the \(libraryName) library.")
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textSecondary)
        }
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
