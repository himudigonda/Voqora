@testable import Voqora
import XCTest

@MainActor
final class AudiobookCreateFlowTests: XCTestCase {
    private let page = TestLinks.url("https://www.example.com/story")
    private let bookID = "0123456789abcdef0123456789abcdef"

    override func tearDown() async throws {
        try? await Task.sleep(nanoseconds: 150_000_000)
        LibraryStubURLProtocol.reset()
        try await super.tearDown()
    }

    private func install(startStatus: Int = 200) {
        LibraryStubURLProtocol.install { request in
            switch (request.method, request.path) {
            case ("POST", "/audiobook"), ("POST", "/audiobook/url"):
                .json(200, LibraryFixtures.estimate)
            case ("POST", "/audiobook/\(self.bookID)/start"):
                startStatus == 200 ? .json(200, #"{"status":"queued"}"#) : .json(startStatus, #"{"detail":"No."}"#)
            case ("GET", "/audiobook"):
                .json(200, "[]")
            default:
                .json(200, "{}")
            }
        }
    }

    private func makeVM() -> AudiobookViewModel {
        AudiobookViewModel(
            service: LibraryStubURLProtocol.makeService(),
            audio: AudioService(startingEngine: false),
            providers: StudioFixtures.providers(connected: false),
            subscribeToEvents: { _ in AsyncStream { $0.finish() } }
        )
    }

    private func waitUntil(_ condition: () -> Bool, attempts: Int = 200) async {
        for _ in 0 ..< attempts {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func jsonBodies(path: String) throws -> [[String: Any]] {
        try LibraryStubURLProtocol.requests.filter { $0.path == path && $0.method == "POST" }.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0.body) as? [String: Any])
        }
    }

    func test_presentEstimate_sendsPerBookDeliverySpeedAndPauseForMing() async throws {
        install()
        let vm = makeVM()

        vm.presentEstimate(
            for: .webPage(page), voice: "ming:US_James", speed: 1.25, engine: "ming",
            pauseScale: 1.5, delivery: SpeechDelivery(emotion: .happy, pace: .slow)
        )
        await waitUntil { vm.pendingEstimate != nil }

        let body = try XCTUnwrap(jsonBodies(path: "/audiobook/url").first)
        XCTAssertEqual(body["delivery"] as? [String: String], ["emotion": "happy", "pace": "slow"])
        XCTAssertEqual(body["engine"] as? String, "ming")
        XCTAssertEqual(body["speed"] as? Double, 1.25)
        XCTAssertEqual(body["pause_scale"] as? Double, 1.5)
        XCTAssertEqual(vm.pendingDelivery, SpeechDelivery(emotion: .happy, pace: .slow))
        XCTAssertEqual(vm.pendingSpeed, 1.25)
        vm.cancelUpload()
    }

    func test_updatePendingNarration_reuploadsWithTheNewVoiceSpeedAndDelivery() async throws {
        install()
        let vm = makeVM()
        vm.presentEstimate(for: .webPage(page), voice: "af_bella", speed: 1, engine: "kokoro", pauseScale: 1, delivery: SpeechDelivery())
        await waitUntil { vm.pendingEstimate != nil }

        vm.updatePendingNarration(voice: "ming:US_James", speed: 1.5, delivery: SpeechDelivery(emotion: .sad))
        await waitUntil { LibraryStubURLProtocol.requests.filter { $0.path == "/audiobook/url" }.count == 2 && vm.pendingEstimate != nil }

        let bodies = try jsonBodies(path: "/audiobook/url")
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[1]["voice"] as? String, "ming:US_James")
        XCTAssertEqual(bodies[1]["engine"] as? String, "ming")
        XCTAssertEqual(bodies[1]["speed"] as? Double, 1.5)
        XCTAssertEqual(bodies[1]["delivery"] as? [String: String], ["emotion": "sad"])
        XCTAssertTrue(LibraryStubURLProtocol.requests.contains { $0.method == "DELETE" && $0.path == "/audiobook/\(bookID)" })
        vm.cancelUpload()
    }

    func test_updatePendingNarration_doesNothingWhenNothingChanged() async {
        install()
        let vm = makeVM()
        vm.presentEstimate(for: .webPage(page), voice: "af_bella", speed: 1, engine: "kokoro", pauseScale: 1, delivery: SpeechDelivery())
        await waitUntil { vm.pendingEstimate != nil }

        vm.updatePendingNarration(voice: "af_bella", speed: 1, pauseScale: 1, delivery: SpeechDelivery())
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(LibraryStubURLProtocol.requests.filter { $0.path == "/audiobook/url" }.count, 1)
        XCTAssertFalse(LibraryStubURLProtocol.requests.contains { $0.method == "DELETE" })
        vm.cancelUpload()
    }

    func test_deliveryIsDroppedWhenTheVoiceStopsBeingMing() async {
        install()
        let vm = makeVM()
        vm.presentEstimate(
            for: .webPage(page), voice: "ming:US_James", speed: 1, engine: "ming",
            pauseScale: 1, delivery: SpeechDelivery(emotion: .happy)
        )
        await waitUntil { vm.pendingEstimate != nil }

        vm.updatePendingNarration(voice: "af_bella")
        await waitUntil { LibraryStubURLProtocol.requests.filter { $0.path == "/audiobook/url" }.count == 2 && vm.pendingEstimate != nil }

        XCTAssertNil(vm.pendingDelivery)
        XCTAssertNil(try jsonBodies(path: "/audiobook/url").last?["delivery"])
        vm.cancelUpload()
    }

    func test_pastedTextBecomesATitledTextDocument() async throws {
        install()
        let vm = makeVM()

        vm.presentEstimate(forText: "Some words to narrate aloud.", title: "My Draft", voice: "af_bella", speed: 1, engine: "kokoro")
        await waitUntil { vm.pendingEstimate != nil }

        let staged = try XCTUnwrap(vm.pendingDocument)
        XCTAssertEqual(staged.lastPathComponent, "My Draft.txt")
        XCTAssertEqual(try String(contentsOf: staged, encoding: .utf8), "Some words to narrate aloud.")
        vm.cancelUpload()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func test_retitlePendingStagesARenamedCopyAndReestimates() async throws {
        install()
        let vm = makeVM()
        vm.presentEstimate(forText: "Some words to narrate aloud.", title: "Draft", voice: "af_bella", speed: 1, engine: "kokoro")
        await waitUntil { vm.pendingEstimate != nil }
        let first = try XCTUnwrap(vm.pendingDocument)

        vm.retitlePending("Final Cut")
        await waitUntil { vm.pendingDocument?.lastPathComponent == "Final Cut.txt" && vm.pendingEstimate != nil }

        XCTAssertEqual(vm.pendingDocument?.lastPathComponent, "Final Cut.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(LibraryStubURLProtocol.requests.filter { $0.method == "POST" && $0.path == "/audiobook" }.count, 2)
        vm.cancelUpload()
    }

    func test_retitlePendingIgnoresWebPagesAndUnchangedTitles() async {
        install()
        let vm = makeVM()
        vm.presentEstimate(for: .webPage(page), voice: "af_bella", speed: 1, engine: "kokoro")
        await waitUntil { vm.pendingEstimate != nil }

        vm.retitlePending("Something")
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(LibraryStubURLProtocol.requests.filter { $0.path == "/audiobook/url" }.count, 1)
        vm.cancelUpload()
    }

    func test_beginProcessingReturnsTrueAndClearsThePendingSource() async {
        install()
        let vm = makeVM()
        vm.presentEstimate(for: .webPage(page), voice: "af_bella", speed: 1, engine: "kokoro")
        await waitUntil { vm.pendingEstimate != nil }

        let started = await vm.beginProcessing(useCleanup: false)

        XCTAssertTrue(started)
        XCTAssertNil(vm.pendingSource)
        XCTAssertNil(vm.pendingEstimate)
        XCTAssertFalse(vm.startingProcessing)
        XCTAssertTrue(LibraryStubURLProtocol.requests.contains { $0.path == "/audiobook/\(bookID)/start" })
    }

    func test_beginProcessingReturnsFalseWhenTheBackendRefuses() async {
        install(startStatus: 500)
        let vm = makeVM()
        vm.presentEstimate(for: .webPage(page), voice: "af_bella", speed: 1, engine: "kokoro")
        await waitUntil { vm.pendingEstimate != nil }

        let started = await vm.beginProcessing(useCleanup: false)

        XCTAssertFalse(started)
        XCTAssertNil(vm.pendingSource)
        XCTAssertEqual(vm.toast?.kind, .error)
    }

    func test_beginProcessingWithoutAnEstimateIsANoOp() async {
        install()
        let vm = makeVM()

        let started = await vm.beginProcessing(useCleanup: false)

        XCTAssertFalse(started)
        XCTAssertNil(vm.toast)
        XCTAssertFalse(vm.startingProcessing)
    }

    func test_beginProcessingWithCleanupNeedsAProvider() async {
        install()
        let vm = makeVM()
        vm.presentEstimate(for: .webPage(page), voice: "af_bella", speed: 1, engine: "kokoro")
        await waitUntil { vm.pendingEstimate != nil }

        let started = await vm.beginProcessing(useCleanup: true)

        XCTAssertFalse(started)
        XCTAssertNotNil(vm.pendingEstimate)
        XCTAssertEqual(vm.toast?.message, AudiobookViewModel.missingProviderMessage)
        vm.cancelUpload()
    }

    func test_formLoadsPastedTextAndCreatesTheBook() async {
        install()
        let vm = makeVM()
        let form = AudiobookCreateForm()
        form.voice = "af_bella"
        form.pasteText = "A short passage that is long enough to narrate."
        form.pasteTitle = "Passage"
        XCTAssertTrue(form.canSubmitText)

        form.submitText(library: vm)
        await waitUntil { vm.pendingEstimate != nil }
        XCTAssertEqual(vm.pendingDocument?.lastPathComponent, "Passage.txt")

        let created = await form.create(library: vm)

        XCTAssertTrue(created)
        XCTAssertEqual(vm.toast?.kind, .success)
        XCTAssertEqual(form.pasteText, "")
        XCTAssertEqual(form.sourceTab, .file)
        XCTAssertFalse(form.isCreating)
    }

    func test_formRejectsShortTextAndBadLinks() {
        let vm = makeVM()
        let form = AudiobookCreateForm()

        form.pasteText = "too short"
        XCTAssertFalse(form.canSubmitText)
        form.submitText(library: vm)
        XCTAssertNil(vm.pendingSource)

        form.linkText = "ftp://example.com/file"
        form.submitLink(library: vm)
        XCTAssertEqual(form.linkProblem, .notWebLink)
        XCTAssertNil(vm.pendingSource)

        form.linkText = "not a link"
        XCTAssertTrue(form.canSubmitLink)
        form.clearLinkProblem()
        XCTAssertNil(form.linkProblem)
    }

    func test_formLinkSubmissionLoadsTheWebPageWithTheChosenNarration() async throws {
        install()
        let vm = makeVM()
        let form = AudiobookCreateForm()
        form.voice = "am_adam"
        form.speed = 1.4
        form.pauseScale = 1.2
        form.linkText = "example.com/story"

        form.submitLink(library: vm)
        await waitUntil { vm.pendingEstimate != nil }

        XCTAssertEqual(vm.pendingSource, .webPage(TestLinks.url("https://example.com/story")))
        let body = try XCTUnwrap(jsonBodies(path: "/audiobook/url").first)
        XCTAssertEqual(body["voice"] as? String, "am_adam")
        XCTAssertEqual(body["speed"] as? Double, 1.4)
        XCTAssertEqual(body["pause_scale"] as? Double, 1.2)
        vm.cancelUpload()
    }

    func test_formNarrationKeyTracksEveryNarrationControl() {
        let form = AudiobookCreateForm()
        let initial = form.narrationKey

        form.speed += 0.25
        XCTAssertNotEqual(form.narrationKey, initial)
        form.speed = initial.speed
        XCTAssertEqual(form.narrationKey, initial)

        form.delivery.emotion = .happy
        XCTAssertNotEqual(form.narrationKey, initial)
    }

    func test_formReplaceSourceCancelsThePendingUpload() async {
        install()
        let vm = makeVM()
        let form = AudiobookCreateForm()
        vm.presentEstimate(for: .webPage(page), voice: "af_bella", speed: 1, engine: "kokoro")
        await waitUntil { vm.pendingEstimate != nil }
        form.titleDraft = "Old"

        form.replaceSource(library: vm)

        XCTAssertNil(vm.pendingSource)
        XCTAssertEqual(form.titleDraft, "")
    }

    func test_discardPendingDraftDropsTheSourceAndEveryQueuedUpload() async throws {
        install()
        let vm = makeVM()
        vm.presentEstimate(forText: "First queued passage of text.", title: "One", voice: "af_bella", speed: 1, engine: "kokoro")
        vm.presentEstimate(forText: "Second queued passage of text.", title: "Two", voice: "af_bella", speed: 1, engine: "kokoro")
        await waitUntil { vm.pendingEstimate != nil }
        XCTAssertEqual(vm.queuedUploadCount, 1)
        let staged = try XCTUnwrap(vm.pendingDocument)

        vm.discardPendingDraft()

        XCTAssertNil(vm.pendingSource)
        XCTAssertNil(vm.pendingEstimate)
        XCTAssertEqual(vm.queuedUploadCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func test_createRequestHoldsOnePendingSourceAtATime() {
        let request = AudiobookCreateRequest()
        let file = TestLinks.url("file:///tmp/book.pdf")

        request.pending = .file(file)
        XCTAssertEqual(request.pending, .file(file))
        request.pending = .text("Hi", title: nil)
        XCTAssertEqual(request.pending, .text("Hi", title: nil))
        request.pending = nil
        XCTAssertNil(request.pending)
    }
}
