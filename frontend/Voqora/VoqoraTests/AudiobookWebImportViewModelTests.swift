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

    private func importPage(_ vm: AudiobookViewModel, voice: String = "af_bella", speed: Double = 1) {
        vm.presentEstimate(for: .webPage(page), voice: voice, speed: speed, engine: "kokoro")
    }

    func test_webPageImportShowsTheEstimate() async throws {
        LibraryStubURLProtocol.install(Self.reply())
        let vm = makeVM()

        importPage(vm, voice: "am_adam", speed: 1.5)

        XCTAssertEqual(vm.pendingSource, .webPage(page))
        XCTAssertNil(vm.pendingDocument)
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

    func test_webPageImportFailureShowsTheMappedMessageWithoutAToast() async {
        LibraryStubURLProtocol.install(Self.reply(failing: .json(422, #"{"detail":"raw","code":"paywalled"}"#)))
        let vm = makeVM()

        importPage(vm)
        await waitUntil { vm.loadingError != nil }

        XCTAssertEqual(vm.loadingError, WebPageImportMessage.codeMessages["paywalled"])
        XCTAssertNil(vm.pendingEstimate)
        XCTAssertNil(vm.toast)
        XCTAssertEqual(vm.pendingSource, .webPage(page))
    }

    func test_startingAWebPageImportClearsThePendingSource() async {
        LibraryStubURLProtocol.install(Self.reply())
        let vm = AudiobookViewModel(
            service: LibraryStubURLProtocol.makeService(),
            audio: AudioService(startingEngine: false),
            providers: StudioFixtures.providers(connected: false),
            subscribeToEvents: { _ in AsyncStream { $0.finish() } },
            listBooks: { [] }
        )
        importPage(vm)
        await waitUntil { vm.pendingEstimate != nil }

        vm.startProcessing(useCleanup: false)
        await waitUntil { vm.pendingSource == nil }

        XCTAssertNil(vm.pendingSource)
    }

    func test_webPageWhileAnotherImportIsPendingIsQueued() {
        LibraryStubURLProtocol.install(Self.reply())
        let vm = makeVM()
        vm.pendingDocument = URL(fileURLWithPath: "/tmp/book.pdf")

        importPage(vm)

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
