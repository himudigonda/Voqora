import Combine
import Foundation

nonisolated struct SecretStore: Sendable {
    let get: @Sendable (KeychainKey) -> String?
    let set: @Sendable (String, KeychainKey) -> Bool
    let delete: @Sendable (KeychainKey) -> Bool

    static let keychain = SecretStore(
        get: { KeychainService.get($0) },
        set: { KeychainService.set($0, for: $1) },
        delete: { KeychainService.delete($0) }
    )
}

@MainActor
final class LLMProviderStore: ObservableObject {
    static let settingsKey = "llmProviderSettings"
    static let activeKey = "llmActiveProvider"

    @Published private(set) var connected: [LLMProvider: LLMProviderSettings] = [:]
    @Published private(set) var activeProvider: LLMProvider?
    private(set) var saveCount = 0

    private let defaults: UserDefaults
    private var legacyMigration: Task<Void, Never>?
    private let secrets: SecretStore
    private let verifier: @MainActor (LLMCredential) async -> LLMVerification

    init(
        defaults: UserDefaults = .standard,
        secrets: SecretStore = .keychain,
        verifier: (@MainActor (LLMCredential) async -> LLMVerification)? = nil
    ) {
        self.defaults = defaults
        self.secrets = secrets
        self.verifier = verifier ?? { credential in
            await AudiobookService().verifyProvider(credential)
        }
        load()
    }

    var connectedProviders: [LLMProvider] {
        LLMProvider.allCases.filter { connected[$0] != nil }
    }

    var activeCredential: LLMCredential? {
        activeProvider.flatMap(credential(for:))
    }

    var needsActiveChoice: Bool {
        activeProvider == nil && connected.count > 1
    }

    func isConnected(_ provider: LLMProvider) -> Bool {
        connected[provider] != nil
    }

    func settings(for provider: LLMProvider) -> LLMProviderSettings {
        connected[provider] ?? LLMProviderSettings(serverURL: provider.defaultServerURL)
    }

    func storedKey(for provider: LLMProvider) -> String {
        secrets.get(provider.keychainKey) ?? ""
    }

    func credential(for provider: LLMProvider) -> LLMCredential? {
        guard let settings = connected[provider] else { return nil }
        let key = storedKey(for: provider)
        if provider.requiresKey, key.isEmpty {
            return nil
        }
        return LLMCredential(provider: provider, apiKey: key, model: settings.model, serverURL: settings.serverURL)
    }

    func verify(_ credential: LLMCredential) async -> LLMVerification {
        await verifier(credential)
    }

    @discardableResult
    func save(_ credential: LLMCredential, makeActive: Bool = false) -> Bool {
        let provider = credential.provider
        if provider.acceptsKey {
            let stored = credential.apiKey.isEmpty
                ? secrets.delete(provider.keychainKey)
                : secrets.set(credential.apiKey, provider.keychainKey) && secrets.get(provider.keychainKey) == credential.apiKey
            guard stored else { return false }
        }
        connected[provider] = LLMProviderSettings(model: credential.model, serverURL: credential.serverURL)
        saveCount += 1
        if makeActive || connected.count == 1 {
            activeProvider = provider
        }
        persist()
        return true
    }

    func use(_ provider: LLMProvider) {
        guard isConnected(provider) else { return }
        activeProvider = provider
        persist()
    }

    func remove(_ provider: LLMProvider) {
        _ = secrets.delete(provider.keychainKey)
        connected[provider] = nil
        if activeProvider == provider || connected.count == 1 {
            activeProvider = connected.count == 1 ? connectedProviders.first : nil
        }
        persist()
    }

    func finishLegacyMigration() async {
        await legacyMigration?.value
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.settingsKey),
              let stored = try? JSONDecoder().decode([String: LLMProviderSettings].self, from: data)
        else {
            adoptLegacyGeminiKey()
            return
        }
        connected = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            LLMProvider(rawValue: key).map { ($0, value) }
        })
        restoreActiveProvider()
        persist()
    }

    private func adoptLegacyGeminiKey() {
        let secrets = secrets
        legacyMigration = Task { [weak self] in
            let hasLegacyKey = await Task.detached { secrets.get(LLMProvider.google.keychainKey) != nil }.value
            guard let self else { return }
            if hasLegacyKey, connected.isEmpty {
                connected = [.google: LLMProviderSettings()]
            }
            restoreActiveProvider()
            persist()
        }
    }

    private func restoreActiveProvider() {
        let storedActive = defaults.string(forKey: Self.activeKey).flatMap(LLMProvider.init(rawValue:))
        activeProvider = activeProvider.flatMap { connected[$0] != nil ? $0 : nil }
            ?? storedActive.flatMap { connected[$0] != nil ? $0 : nil }
            ?? (connected.count == 1 ? connectedProviders.first : nil)
    }

    private func persist() {
        let stored = Dictionary(uniqueKeysWithValues: connected.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.settingsKey)
        }
        defaults.set(activeProvider?.rawValue, forKey: Self.activeKey)
    }
}
