import Combine
import Foundation

@MainActor
final class AudiobookshelfSettingsStore: ObservableObject {
    static let serverKey = "audiobookshelfServerURL"
    static let libraryIDKey = "audiobookshelfLibraryID"
    static let libraryNameKey = "audiobookshelfLibraryName"
    static let folderIDKey = "audiobookshelfFolderID"
    static let missingTokenMessage = "Paste an API token from Audiobookshelf."
    static let tokenStorageFailure = "Voqora could not save the token to your Keychain. Try again."
    static let tokenForNewServerMessage = "Paste the API token for this server. Voqora only sends a saved token to the server it was verified with."
    static let maximumTokenLength = 4096

    enum ConnectionState: Equatable {
        case idle
        case testing
        case connected
        case failed(String)
    }

    @Published var serverText: String
    @Published private(set) var hasToken: Bool
    @Published private(set) var libraries: [AudiobookshelfLibrary] = []
    @Published private(set) var libraryID: String?
    @Published private(set) var libraryName: String?
    @Published private(set) var folderID: String?
    @Published private(set) var connection: ConnectionState = .idle
    @Published private(set) var tokenError: String?

    private let client: any AudiobookshelfServing
    private let secrets: SecretStore
    private let defaults: UserDefaults
    private var token: String
    private var tokenServer: String?
    private var testGeneration = 0

    init(client: any AudiobookshelfServing, secrets: SecretStore, defaults: UserDefaults) {
        self.client = client
        self.secrets = secrets
        self.defaults = defaults
        let storedToken = secrets.get(.audiobookshelfToken) ?? ""
        let storedServer = defaults.string(forKey: Self.serverKey) ?? ""
        token = storedToken
        hasToken = !storedToken.isEmpty
        tokenServer = storedToken.isEmpty || storedServer.isEmpty ? nil : storedServer
        serverText = storedServer
        libraryID = defaults.string(forKey: Self.libraryIDKey)
        libraryName = defaults.string(forKey: Self.libraryNameKey)
        folderID = defaults.string(forKey: Self.folderIDKey)
    }

    var address: AudiobookshelfServerAddress {
        AudiobookshelfServerAddress(serverText)
    }

    var bookLibraries: [AudiobookshelfLibrary] {
        libraries.filter(\.holdsBooks)
    }

    var selectedLibrary: AudiobookshelfLibrary? {
        libraries.first { $0.id == libraryID }
    }

    var needsTokenForAddress: Bool {
        guard hasToken, let tokenServer, let server = address.url else { return false }
        return server.absoluteString != tokenServer
    }

    var destination: AudiobookshelfDestination? {
        guard hasToken, tokenServer == savedServer, let server = AudiobookshelfServerAddress(savedServer).url,
              let libraryID, let folderID
        else { return nil }
        return AudiobookshelfDestination(server: server, token: token, libraryID: libraryID, folderID: folderID)
    }

    var isConfigured: Bool {
        destination != nil
    }

    private var savedServer: String {
        defaults.string(forKey: Self.serverKey) ?? ""
    }

    @discardableResult
    func saveToken(_ rawToken: String) -> Bool {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maximumTokenLength else {
            tokenError = Self.missingTokenMessage
            return false
        }
        guard secrets.set(trimmed, .audiobookshelfToken) else {
            tokenError = Self.tokenStorageFailure
            return false
        }
        tokenError = nil
        token = trimmed
        tokenServer = nil
        hasToken = true
        connection = .idle
        return true
    }

    func testConnection() async {
        guard let server = address.url else {
            connection = .failed(address.error ?? AudiobookshelfServerAddress.malformedMessage)
            return
        }
        guard hasToken else {
            connection = .failed(Self.missingTokenMessage)
            return
        }
        guard tokenServer == nil || tokenServer == server.absoluteString else {
            connection = .failed(Self.tokenForNewServerMessage)
            return
        }
        serverText = server.absoluteString
        testGeneration &+= 1
        let generation = testGeneration
        connection = .testing
        do {
            let found = try await client.libraries(server: server, token: token)
            guard generation == testGeneration else { return }
            if server.absoluteString != savedServer {
                clearLibrarySelection()
                defaults.set(server.absoluteString, forKey: Self.serverKey)
            }
            tokenServer = server.absoluteString
            libraries = found
            guard !bookLibraries.isEmpty else {
                connection = .failed(AudiobookshelfError.noBookLibraries.localizedDescription)
                return
            }
            connection = .connected
            if let current = selectedLibrary, current.holdsBooks {
                selectLibrary(current.id, folderID: folderID)
            } else if let first = bookLibraries.first {
                selectLibrary(first.id)
            }
            VoqoraLog.info("Audiobookshelf", "Connection verified", ["libraries": "\(bookLibraries.count)"])
        } catch {
            guard generation == testGeneration else { return }
            let shelfError = error as? AudiobookshelfError
            VoqoraLog.warn("Audiobookshelf", "Connection test failed", ["failureCode": shelfError?.failureCode ?? "abs_unreachable"])
            connection = .failed(shelfError?.localizedDescription ?? AudiobookshelfError.unreachable.localizedDescription)
        }
    }

    func selectLibrary(_ id: String, folderID requestedFolderID: String? = nil) {
        guard let library = libraries.first(where: { $0.id == id }), library.holdsBooks else { return }
        let folder = library.folders.first { $0.id == requestedFolderID } ?? library.folders.first
        libraryID = library.id
        libraryName = library.name
        folderID = folder?.id
        defaults.set(library.id, forKey: Self.libraryIDKey)
        defaults.set(library.name, forKey: Self.libraryNameKey)
        defaults.set(folder?.id, forKey: Self.folderIDKey)
    }

    func selectFolder(_ id: String) {
        guard let library = selectedLibrary, library.folders.contains(where: { $0.id == id }) else { return }
        folderID = id
        defaults.set(id, forKey: Self.folderIDKey)
    }

    func disconnect() {
        _ = secrets.delete(.audiobookshelfToken)
        token = ""
        tokenServer = nil
        hasToken = false
        tokenError = nil
        libraries = []
        connection = .idle
        clearLibrarySelection()
        defaults.removeObject(forKey: Self.serverKey)
        serverText = ""
        VoqoraLog.info("Audiobookshelf", "Disconnected")
    }

    private func clearLibrarySelection() {
        libraryID = nil
        libraryName = nil
        folderID = nil
        for key in [Self.libraryIDKey, Self.libraryNameKey, Self.folderIDKey] {
            defaults.removeObject(forKey: key)
        }
    }
}
