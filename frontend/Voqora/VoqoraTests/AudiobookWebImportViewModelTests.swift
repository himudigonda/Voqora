@testable import Voqora
import XCTest

@MainActor
final class AudiobookWebImportViewModelTests: XCTestCase {
    private let page = TestLinks.url("https://www.example.com/story")

    override func tearDown() {
        LibraryStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeVM() -> AudiobookViewModel {
        AudiobookViewModel(service: LibraryStubURLProtocol.makeService(), audio: AudioService(startingEngine: false), providers: StudioFixtures.providers(connected: false))
    }

    private func waitUntil(_ condition: () -> Bool, attempts: Int = 150) async {
        for _ in 0 ..< attempts {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func reply(failing failure: LibraryStubURLProtocol.Reply? = nil) -> @Sendable (LibraryStubURLProtocol.Recorded) -> LibraryStubURLProtocol.Reply {
        { request in
            guard request.path == "/audiobook/url" else { return .json(200, "{}") }
            return failure ?? .json(200, LibraryFixtures.estimate)
        }
    }

    func test_importWebPage_closesTheSheetAndShowsTheEstimate() async throws {
        LibraryStubURLProtocol.install(Self.reply())
        let vm = makeVM()
        vm.presentWebPageImport()
        XCTAssertTrue(vm.isWebPageImportPresented)

        vm.importWebPage(page, voice: "am_adam", speed: 1.5)

        XCTAssertFalse(vm.isWebPageImportPresented)
        XCTAssertEqual(vm.pendingSource, .webPage(page))
        XCTAssertNil(vm.pendingDocument)
        XCTAssertEqual(vm.webPageDraft, page.absoluteString)
        XCTAssertTrue(vm.uploadInProgress)
        await waitUntil { vm.pendingEstimate != nil }

        XCTAssertEqual(vm.pendingEstimate?.title, "An Article")
        XCTAssertFalse(vm.uploadInProgress)
        let request = try XCTUnwrap(LibraryStubURLProtocol.requests.first { $0.path == "/audiobook/url" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["voice"] as? String, "am_adam")
        XCTAssertEqual(body["speed"] as? Double, 1.5)
        XCTAssertEqual(body["engine"] as? String, "kokoro")
        vm.cancelUpload()
        XCTAssertNil(vm.pendingSource)
    }

    func test_importWebPage_failureShowsTheMappedMessageWithoutAToast() async {
        LibraryStubURLProtocol.install(Self.reply(failing: .json(422, #"{"detail":"raw","code":"paywalled"}"#)))
        let vm = makeVM()

        vm.importWebPage(page, voice: "af_bella", speed: 1)
        await waitUntil { vm.loadingError != nil }

        XCTAssertEqual(vm.loadingError, WebPageImportMessage.codeMessages["paywalled"])
        XCTAssertNil(vm.pendingEstimate)
        XCTAssertNil(vm.toast)
        XCTAssertEqual(vm.pendingSource, .webPage(page))
    }

    func test_editWebPageLink_reopensTheSheetWithTheLastAddress() async {
        LibraryStubURLProtocol.install(Self.reply(failing: .json(504, #"{"detail":"raw","code":"timeout"}"#)))
        let vm = makeVM()
        vm.importWebPage(page, voice: "af_bella", speed: 1)
        await waitUntil { vm.loadingError != nil }

        vm.editWebPageLink()

        XCTAssertNil(vm.pendingSource)
        XCTAssertNil(vm.loadingError)
        XCTAssertTrue(vm.isWebPageImportPresented)
        XCTAssertEqual(vm.webPageDraft, page.absoluteString)
    }

    func test_startingAWebPageImportClearsTheLinkDraft() async {
        LibraryStubURLProtocol.install(Self.reply())
        let vm = AudiobookViewModel(
            service: LibraryStubURLProtocol.makeService(),
            audio: AudioService(startingEngine: false),
            providers: StudioFixtures.providers(connected: false),
            subscribeToEvents: { _ in AsyncStream { $0.finish() } },
            listBooks: { [] }
        )
        vm.importWebPage(page, voice: "af_bella", speed: 1)
        await waitUntil { vm.pendingEstimate != nil }

        vm.startProcessing(useCleanup: false)
        await waitUntil { vm.pendingSource == nil }

        XCTAssertNil(vm.pendingSource)
        XCTAssertEqual(vm.webPageDraft, "")
    }

    func test_editWebPageLink_ignoresDocumentImports() {
        let vm = makeVM()
        vm.pendingDocument = URL(fileURLWithPath: "/tmp/book.pdf")

        vm.editWebPageLink()

        XCTAssertNotNil(vm.pendingDocument)
        XCTAssertFalse(vm.isWebPageImportPresented)
    }

    func test_webPageWhileAnotherImportIsPendingIsQueued() {
        LibraryStubURLProtocol.install(Self.reply())
        let vm = makeVM()
        vm.pendingDocument = URL(fileURLWithPath: "/tmp/book.pdf")

        vm.presentWebPageImport()
        XCTAssertFalse(vm.isWebPageImportPresented)

        vm.importWebPage(page, voice: "af_bella", speed: 1)

        XCTAssertEqual(vm.queuedUploadCount, 1)
        XCTAssertEqual(vm.toast?.message, "Queued example.com")
        XCTAssertEqual(vm.pendingDocument, URL(fileURLWithPath: "/tmp/book.pdf"))
    }

    func test_importDefaultsPreferTheAudiobookPreferences() {
        let vm = makeVM()
        let savedVoice = vm.defaultBookVoice
        let savedSpeed = vm.defaultBookSpeed
        defer {
            vm.defaultBookVoice = savedVoice
            vm.defaultBookSpeed = savedSpeed
        }

        vm.defaultBookVoice = ""
        vm.defaultBookSpeed = 0
        XCTAssertEqual(vm.importVoice(fallback: "bf_emma"), "bf_emma")
        XCTAssertEqual(vm.importSpeed(fallback: 1.2), 1.2)

        vm.defaultBookVoice = "am_adam"
        vm.defaultBookSpeed = 1.5
        XCTAssertEqual(vm.importVoice(fallback: "bf_emma"), "am_adam")
        XCTAssertEqual(vm.importSpeed(fallback: 1.2), 1.5)
    }

    func test_fileKindAndFailureCodesNeverIncludeTheLink() {
        XCTAssertEqual(AudiobookViewModel.fileKind(of: .document(URL(fileURLWithPath: "/tmp/a.EPUB"))), "epub")
        XCTAssertEqual(AudiobookViewModel.fileKind(of: .webPage(page)), "url")
        XCTAssertEqual(AudiobookViewModel.webImportFailureCode(for: AudiobookAPIFailure(statusCode: 403, code: "blocked_address")), "blocked_address")
        XCTAssertEqual(AudiobookViewModel.webImportFailureCode(for: AudiobookAPIFailure(statusCode: 500)), "web_import_http_500")
        XCTAssertEqual(AudiobookViewModel.webImportFailureCode(for: URLError(.timedOut)), "web_import_transport_failed")
    }
}
