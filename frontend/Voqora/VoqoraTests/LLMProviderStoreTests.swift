import Foundation
@testable import Voqora
import XCTest

private final class ThreadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    var values: [Bool] {
        lock.withLock { storage }
    }

    func record(_ value: Bool) {
        lock.withLock { storage.append(value) }
    }
}

@MainActor
final class LLMProviderStoreTests: XCTestCase {
    private final class MemorySecrets: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]

        var values: [String: String] {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }

        func read(_ key: String) -> String? {
            lock.withLock { storage[key] }
        }

        func write(_ key: String, _ value: String?) {
            lock.withLock { storage[key] = value }
        }

        var store: SecretStore {
            SecretStore(
                get: { [unowned self] in read($0.rawValue) },
                set: { [unowned self] in write($1.rawValue, $0); return true },
                delete: { [unowned self] in write($0.rawValue, nil); return true }
            )
        }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var secrets: MemorySecrets!

    override func setUp() {
        super.setUp()
        suiteName = "LLMProviderStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = MemorySecrets()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> LLMProviderStore {
        LLMProviderStore(defaults: defaults, secrets: secrets.store) { _ in
            LLMVerification(verified: true, models: [], error: nil)
        }
    }

    func testFirstSavedProviderBecomesActive() {
        let store = makeStore()
        XCTAssertNil(store.activeCredential)

        XCTAssertTrue(store.save(LLMCredential(provider: .anthropic, apiKey: "sk-ant", model: "", serverURL: "")))

        XCTAssertEqual(store.activeProvider, .anthropic)
        XCTAssertEqual(store.activeCredential?.apiKey, "sk-ant")
        XCTAssertEqual(store.activeCredential?.resolvedModel, "claude-haiku-5-5")
    }

    func testSettingsAndActiveProviderSurviveRelaunch() {
        let store = makeStore()
        store.save(LLMCredential(provider: .openai, apiKey: "sk-1", model: "", serverURL: ""))
        store.save(LLMCredential(provider: .ollama, apiKey: "", model: "qwen3", serverURL: "http://localhost:11434/v1"))
        store.use(.ollama)

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.connectedProviders, [.openai, .ollama])
        XCTAssertEqual(relaunched.activeProvider, .ollama)
        XCTAssertEqual(relaunched.activeCredential?.model, "qwen3")
        XCTAssertEqual(relaunched.activeCredential?.apiKey, "")
    }

    func testRemovingActiveProviderFallsBackToAnotherConnectedOne() {
        let store = makeStore()
        store.save(LLMCredential(provider: .groq, apiKey: "gsk", model: "", serverURL: ""))
        store.save(LLMCredential(provider: .xai, apiKey: "xai", model: "", serverURL: ""))
        store.use(.xai)

        store.remove(.xai)

        XCTAssertEqual(store.activeProvider, .groq)
        XCTAssertNil(secrets.read(KeychainKey.llmAPIKey(.xai).rawValue))
    }

    private func connect(_ store: LLMProviderStore, _ providers: LLMProvider..., active: LLMProvider? = nil) {
        for provider in providers {
            store.save(LLMCredential(provider: provider, apiKey: "key-\(provider.rawValue)", model: "", serverURL: ""))
        }
        if let active {
            store.use(active)
        }
    }

    func testSecondProviderDoesNotTakeOverUnlessAsked() {
        let store = makeStore()
        connect(store, .openai, .groq)
        XCTAssertEqual(store.activeProvider, .openai)

        store.save(LLMCredential(provider: .xai, apiKey: "xai", model: "", serverURL: ""), makeActive: true)
        XCTAssertEqual(store.activeProvider, .xai)
    }

    func testRemovingActiveProviderWithSeveralLeftLeavesNoneActive() {
        let store = makeStore()
        connect(store, .openai, .groq, .xai, active: .groq)

        store.remove(.groq)

        XCTAssertNil(store.activeProvider)
        XCTAssertNil(store.activeCredential)
        XCTAssertTrue(store.needsActiveChoice)
        XCTAssertEqual(store.connectedProviders, [.openai, .xai])
    }

    func testRemovingActiveProviderWithOneLeftPromotesIt() {
        let store = makeStore()
        connect(store, .openai, .groq, active: .groq)

        store.remove(.groq)

        XCTAssertEqual(store.activeProvider, .openai)
        XCTAssertFalse(store.needsActiveChoice)
    }

    func testRemovingInactiveProviderKeepsActive() {
        let store = makeStore()
        connect(store, .openai, .groq, .xai, active: .groq)

        store.remove(.xai)

        XCTAssertEqual(store.activeProvider, .groq)
    }

    func testRemovingTheLastProviderClearsActive() {
        let store = makeStore()
        connect(store, .openai)

        store.remove(.openai)

        XCTAssertNil(store.activeProvider)
        XCTAssertFalse(store.needsActiveChoice)
    }

    func testNoActiveProviderSurvivesRelaunchWithoutSilentPromotion() {
        let store = makeStore()
        connect(store, .openai, .groq, .xai, active: .groq)
        store.remove(.groq)

        let relaunched = makeStore()

        XCTAssertNil(relaunched.activeProvider)
        XCTAssertTrue(relaunched.needsActiveChoice)
    }

    func testChoosingAfterRemovalMakesThatProviderActive() {
        let store = makeStore()
        connect(store, .openai, .groq, .xai, active: .groq)
        store.remove(.groq)

        store.use(.xai)

        XCTAssertEqual(store.activeProvider, .xai)
        XCTAssertFalse(store.needsActiveChoice)
    }

    func testExistingGeminiKeyIsAdoptedWithoutReentry() async {
        secrets.write(KeychainKey.llmAPIKey(.google).rawValue, "AIza-existing")

        let store = makeStore()
        await store.finishLegacyMigration()

        XCTAssertEqual(store.activeProvider, .google)
        XCTAssertEqual(store.activeCredential?.apiKey, "AIza-existing")
        XCTAssertEqual(KeychainKey.llmAPIKey(.google).rawValue, "com.himudigonda.Voqora.gemini_api_key")
    }

    func testStoreInitDoesNotReadSecretsOnTheMainThread() async {
        let readThreads = ThreadLog()
        let probe = SecretStore(
            get: { _ in readThreads.record(Thread.isMainThread); return "AIza" },
            set: { _, _ in true },
            delete: { _ in true }
        )
        let store = LLMProviderStore(defaults: defaults, secrets: probe) { _ in
            LLMVerification(verified: true, models: [], error: nil)
        }
        XCTAssertTrue(readThreads.values.isEmpty)

        await store.finishLegacyMigration()

        XCTAssertEqual(readThreads.values, [false])
        XCTAssertEqual(store.activeProvider, .google)
    }

    func testLegacyMigrationDoesNotOverrideAProviderSavedMeanwhile() async {
        secrets.write(KeychainKey.llmAPIKey(.google).rawValue, "AIza-existing")
        let store = makeStore()
        store.save(LLMCredential(provider: .openai, apiKey: "sk-1", model: "", serverURL: ""))

        await store.finishLegacyMigration()

        XCTAssertEqual(store.connectedProviders, [.openai])
        XCTAssertEqual(store.activeProvider, .openai)
    }

    func testCloudProviderWithoutKeyHasNoCredential() {
        let store = makeStore()
        store.save(LLMCredential(provider: .cerebras, apiKey: "csk", model: "", serverURL: ""))
        secrets.write(KeychainKey.llmAPIKey(.cerebras).rawValue, nil)

        XCTAssertNil(store.activeCredential)
    }

    func testEveryProviderKeyIsErasedWithLocalData() {
        let keys = Set(KeychainKey.allCases.map(\.rawValue))
        for provider in LLMProvider.allCases {
            XCTAssertTrue(keys.contains(KeychainKey.llmAPIKey(provider).rawValue), provider.rawValue)
        }
    }

    func testCredentialHeaders() throws {
        var request = try URLRequest(url: XCTUnwrap(URL(string: "http://127.0.0.1/")))
        LLMCredential(provider: .custom, apiKey: "", model: "m", serverURL: "http://10.0.0.2/v1").apply(to: &request)

        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Voqora-LLM-Provider"), "custom")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Voqora-LLM-Key"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Voqora-LLM-Model"), "m")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Voqora-LLM-Base-URL"), "http://10.0.0.2/v1")
    }
}
