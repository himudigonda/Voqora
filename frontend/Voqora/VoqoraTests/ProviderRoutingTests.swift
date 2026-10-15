@testable import Voqora
import XCTest

@MainActor
final class ProviderRoutingTests: XCTestCase {
    private func decodeBook(
        status: String = "failed",
        error: String? = "Google rejected the API key.",
        errorCode: String? = "llm_auth_failed",
        provider: String? = "google",
        model: String? = "gemini-3.8-flash",
        usesCleanup: Bool = true
    ) throws -> Audiobook {
        var json: [String: Any] = [
            "book_id": "b1",
            "title": "Atlas.pdf",
            "created_at": "2026-01-01T00:00:00Z",
            "page_count": 4,
            "status": status,
            "phase_progress": ["page_done": 1, "page_total": 4],
            "sections": [],
            "page_to_time": [String: Double](),
            "total_audio_seconds": 0,
            "failed_pages": [Int](),
            "engine": "kokoro",
            "voice": "af_bella",
            "speed": 1.0,
            "uses_gemini_cleanup": usesCleanup,
        ]
        json["error"] = error
        json["error_code"] = errorCode
        json["llm_provider"] = provider
        json["llm_model"] = model
        return try JSONDecoder().decode(Audiobook.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func test_bookDecodesFailureCodeAndCleanupProvider() throws {
        let book = try decodeBook()

        XCTAssertEqual(book.errorCode, "llm_auth_failed")
        XCTAssertEqual(book.cleanupProvider, .google)
        XCTAssertEqual(book.llmModel, "gemini-3.8-flash")
        XCTAssertEqual(book.cleanedWithName, "Google")
        XCTAssertEqual(book.providerToFix, .google)
    }

    func test_bookWithoutProviderFieldsStillDecodes() throws {
        let book = try decodeBook(error: nil, errorCode: nil, provider: nil, model: nil)

        XCTAssertNil(book.cleanupProvider)
        XCTAssertNil(book.cleanedWithName)
        XCTAssertNil(book.providerToFix)
    }

    func test_nonProviderFailureHasNoFixAction() throws {
        XCTAssertNil(try decodeBook(errorCode: "processing_failed").providerToFix)
        XCTAssertNil(try decodeBook(status: "done", errorCode: "llm_auth_failed").providerToFix)
    }

    func test_failureCaptionShowsBackendReason() throws {
        let status = try decodeBook().displayStatus

        XCTAssertEqual(status.failureReason, "Google rejected the API key.")
        XCTAssertEqual(status.detailedCaption, "Google rejected the API key.")
    }

    func test_failureCaptionFallsBackWhenReasonIsMissing() throws {
        let status = try decodeBook(error: nil).displayStatus

        XCTAssertNil(status.failureReason)
        XCTAssertEqual(status.detailedCaption, "Failed. Click to retry.")
        XCTAssertEqual(ProcessingStatus.failed(reason: "  ").detailedCaption, "Failed. Click to retry.")
        XCTAssertEqual(ProcessingStatus.ready.detailedCaption, "Ready")
    }

    func test_retryContinuesSilentlyWhenProviderIsUnchanged() {
        XCTAssertEqual(
            AudiobookViewModel.retryDecision(requiresCleanup: true, startedWith: .google, active: .google, connected: [.google, .openai]),
            .proceed(.google)
        )
        XCTAssertEqual(
            AudiobookViewModel.retryDecision(requiresCleanup: true, startedWith: nil, active: .openai, connected: [.openai]),
            .proceed(.openai)
        )
    }

    func test_retryAsksWhenActiveProviderDiffers() {
        XCTAssertEqual(
            AudiobookViewModel.retryDecision(requiresCleanup: true, startedWith: .google, active: .openai, connected: [.google, .openai]),
            .confirmSwitch(startedWith: .google, active: .openai, startedWithConnected: true)
        )
        XCTAssertEqual(
            AudiobookViewModel.retryDecision(requiresCleanup: true, startedWith: .google, active: .openai, connected: [.openai]),
            .confirmSwitch(startedWith: .google, active: .openai, startedWithConnected: false)
        )
    }

    func test_retryNeedsProviderWhenNoneIsActive() {
        XCTAssertEqual(
            AudiobookViewModel.retryDecision(requiresCleanup: true, startedWith: .google, active: nil, connected: []),
            .needsProvider
        )
        XCTAssertEqual(
            AudiobookViewModel.retryDecision(requiresCleanup: true, startedWith: nil, active: nil, connected: [.groq, .xai]),
            .needsProvider
        )
    }

    func test_retryWithoutCleanupNeverNeedsProvider() {
        XCTAssertEqual(
            AudiobookViewModel.retryDecision(requiresCleanup: false, startedWith: .google, active: nil, connected: []),
            .proceed(nil)
        )
    }

    func test_cleaningCountOnlyCountsProcessingBooksOnThatProvider() throws {
        let google = try decodeBook(status: "cleaning", error: nil, errorCode: nil, provider: "google")
        let openai = try decodeBook(status: "cleaning", error: nil, errorCode: nil, provider: "openai")
        let finished = try decodeBook(status: "done", error: nil, errorCode: nil, provider: "google")
        let books = [google, openai, finished]

        XCTAssertEqual(
            AudiobookViewModel.cleaningBookCount(provider: .google, activeProvider: .google, books: books, states: [:]),
            1
        )
        XCTAssertEqual(
            AudiobookViewModel.cleaningBookCount(provider: .anthropic, activeProvider: .anthropic, books: books, states: [:]),
            0
        )
    }

    func test_cleaningCountAttributesUnlabelledBooksToTheActiveProvider() throws {
        let unlabelled = try decodeBook(status: "cleaning", error: nil, errorCode: nil, provider: nil)

        XCTAssertEqual(
            AudiobookViewModel.cleaningBookCount(provider: .google, activeProvider: .google, books: [unlabelled], states: [:]),
            1
        )
        XCTAssertEqual(
            AudiobookViewModel.cleaningBookCount(provider: .openai, activeProvider: .google, books: [unlabelled], states: [:]),
            0
        )
    }

    func test_estimateIsStaleOnlyWhenProviderOrModelChanged() {
        let credential = LLMCredential(provider: .google, apiKey: "k", model: "", serverURL: "")
        var estimate = AudiobookEstimateResponse(
            bookID: "b", title: "A", pageCount: 1, wordCountEstimate: 1,
            estimatedProcessingSeconds: 1, estimatedAudioSeconds: 1, estimatedCostUsd: 0,
            maximumCostUsd: nil, estimatedTokenCount: 1, isImageOnly: false, costWarning: false,
            duplicateOfBookID: nil, duplicateOfTitle: nil
        )

        XCTAssertTrue(AudiobookViewModel.isEstimateStale(estimate, credential: credential))
        XCTAssertFalse(AudiobookViewModel.isEstimateStale(estimate, credential: nil))

        estimate.llmProvider = "google"
        estimate.llmModel = credential.resolvedModel
        XCTAssertFalse(AudiobookViewModel.isEstimateStale(estimate, credential: credential))

        estimate.llmProvider = "openai"
        XCTAssertTrue(AudiobookViewModel.isEstimateStale(estimate, credential: credential))

        estimate.llmProvider = "google"
        estimate.llmModel = "gemini-other"
        XCTAssertTrue(AudiobookViewModel.isEstimateStale(estimate, credential: credential))
        XCTAssertTrue(AudiobookViewModel.isEstimateStale(estimate, credential: nil))
    }

    func test_removalNoticeForActiveProviderListsCleaningBooksAndSuccessor() {
        let message = ProviderRemovalNotice.message(provider: .google, isActive: true, cleaningCount: 2, remaining: [.openai])

        XCTAssertTrue(message.contains("2 audiobooks are cleaning with Google"))
        XCTAssertTrue(message.contains("Audiobooks will switch to OpenAI."))
        XCTAssertTrue(message.contains("Keychain"))
    }

    func test_removalNoticeAsksForAChoiceWhenSeveralRemain() {
        let message = ProviderRemovalNotice.message(provider: .google, isActive: true, cleaningCount: 0, remaining: [.openai, .groq])

        XCTAssertTrue(message.contains("choose which provider audiobooks use"))
        XCTAssertFalse(message.contains("cleaning with"))
    }

    func test_removalNoticeForInactiveProviderIsPlain() {
        let message = ProviderRemovalNotice.message(provider: .ollama, isActive: false, cleaningCount: 3, remaining: [.openai])

        XCTAssertEqual(message, "Voqora forgets this connection.")
        XCTAssertEqual(ProviderRemovalNotice.title(for: .ollama), "Remove Ollama?")
    }

    private final class MemorySecrets: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]

        var store: SecretStore {
            SecretStore(
                get: { key in self.lock.withLock { self.storage[key.rawValue] } },
                set: { value, key in self.lock.withLock { self.storage[key.rawValue] = value }; return true },
                delete: { key in self.lock.withLock { self.storage[key.rawValue] = nil }; return true }
            )
        }
    }

    private func makeFixViewModel(secrets: MemorySecrets) -> AudiobookViewModel {
        let defaults = UserDefaults(suiteName: "ProviderRoutingTests.\(UUID().uuidString)")!
        let store = LLMProviderStore(defaults: defaults, secrets: secrets.store) { _ in
            LLMVerification(verified: true, models: [], error: nil)
        }
        store.save(LLMCredential(provider: .google, apiKey: "key-1", model: "", serverURL: ""))
        return AudiobookViewModel(audio: AudioService(startingEngine: false), providers: store)
    }

    func test_resumeIsOfferedWhenSavingAnUnchangedCredentialAfterAProviderFailure() throws {
        let viewModel = makeFixViewModel(secrets: MemorySecrets())
        let book = try decodeBook(errorCode: "llm_billing_failed")

        viewModel.fixProvider(for: book)
        viewModel.providers.save(LLMCredential(provider: .google, apiKey: "key-1", model: "", serverURL: ""))
        viewModel.endProviderFix()
        viewModel.offerResumeAfterFix()

        XCTAssertEqual(viewModel.resumeOffer?.book.bookID, "b1")
    }

    func test_resumeIsNotOfferedWhenNothingWasSaved() throws {
        let viewModel = makeFixViewModel(secrets: MemorySecrets())
        let book = try decodeBook(errorCode: "llm_unreachable")

        viewModel.fixProvider(for: book)
        viewModel.endProviderFix()
        viewModel.offerResumeAfterFix()

        XCTAssertNil(viewModel.resumeOffer)
    }

    func test_resumeIsOfferedAfterSavingAChangedCredential() throws {
        let viewModel = makeFixViewModel(secrets: MemorySecrets())
        let book = try decodeBook()

        viewModel.fixProvider(for: book)
        viewModel.providers.save(LLMCredential(provider: .google, apiKey: "key-2", model: "", serverURL: ""))
        viewModel.endProviderFix()
        viewModel.offerResumeAfterFix()

        XCTAssertNotNil(viewModel.resumeOffer)
    }
}
