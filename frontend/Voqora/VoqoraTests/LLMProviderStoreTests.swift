import Foundation
@testable import Voqora
import XCTest

@MainActor
final class LLMProviderStoreTests: XCTestCase {
    private final class MemorySecrets: @unchecked Sendable {
        var values: [String: String] = [:]

        var store: SecretStore {
            SecretStore(
                get: { [unowned self] in values[$0.rawValue] },
                set: { [unowned self] in values[$1.rawValue] = $0; return true },
                delete: { [unowned self] in values[$0.rawValue] = nil; return true }
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
        XCTAssertNil(secrets.values[KeychainKey.llmAPIKey(.xai).rawValue])
    }

    func testExistingGeminiKeyIsAdoptedWithoutReentry() {
        secrets.values[KeychainKey.llmAPIKey(.google).rawValue] = "AIza-existing"

        let store = makeStore()

        XCTAssertEqual(store.activeProvider, .google)
        XCTAssertEqual(store.activeCredential?.apiKey, "AIza-existing")
        XCTAssertEqual(KeychainKey.llmAPIKey(.google).rawValue, "com.himudigonda.Voqora.gemini_api_key")
    }

    func testCloudProviderWithoutKeyHasNoCredential() {
        let store = makeStore()
        store.save(LLMCredential(provider: .cerebras, apiKey: "csk", model: "", serverURL: ""))
        secrets.values[KeychainKey.llmAPIKey(.cerebras).rawValue] = nil

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
