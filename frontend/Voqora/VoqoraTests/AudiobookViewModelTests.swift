@testable import Voqora
import XCTest

@MainActor
final class AudiobookViewModelTests: XCTestCase {
    private enum PlaybackFailure: Error {
        case unavailable
    }

    override func setUp() {
        super.setUp()
        BackendConnection.shared.invalidate()
    }

    private func makeVM(localAudioURL: (@MainActor (String) async throws -> URL)? = nil) -> AudiobookViewModel {
        AudiobookViewModel(audio: AudioService(startingEngine: false), localAudioURL: localAudioURL)
    }

    private func makeBook(id: String = "book-1", status: String = "done") -> Audiobook {
        Audiobook(
            bookID: id,
            title: "Test Book.pdf",
            createdAt: "2026-01-01T00:00:00Z",
            pageCount: 10,
            status: status,
            phaseProgress: PhaseProgress(pageDone: 10, pageTotal: 10),
            sections: [],
            pageToTime: [:],
            totalAudioSeconds: 600,
            failedPages: [],
            estimated: nil,
            actual: nil,
            engine: "kokoro",
            voice: "af_bella",
            speed: 1.0,
            usesLLMCleanup: false,
            budget: nil,
            error: nil
        )
    }

    private func makeEstimate(bookID: String) -> AudiobookEstimateResponse {
        AudiobookEstimateResponse(
            bookID: bookID, title: "A", pageCount: 1, wordCountEstimate: 1,
            estimatedProcessingSeconds: 1, estimatedAudioSeconds: 1, estimatedCostUsd: 0,
            maximumCostUsd: nil, estimatedTokenCount: 1, isImageOnly: false, costWarning: false,
            duplicateOfBookID: nil, duplicateOfTitle: nil
        )
    }

    private func makeTempFile(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("content".utf8).write(to: url)
        return url
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitUntil(_ condition: () -> Bool, attempts: Int = 100) async {
        for _ in 0 ..< attempts {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func test_playerViewFlag_defaultsFalse() {
        XCTAssertFalse(makeVM().isPlayerViewActive)
    }

    func test_nowPlayingBar_hiddenWhenNothingPlayingRegardlessOfPlayerFlag() {
        let vm = makeVM()
        XCTAssertNil(vm.nowPlaying)
        XCTAssertFalse(vm.isNowPlayingBarVisible)

        vm.isPlayerViewActive = true
        XCTAssertFalse(vm.isNowPlayingBarVisible)
    }

    func test_nowPlayingBar_truthTable() {
        let vm = makeVM()
        vm.nowPlaying = makeBook()

        vm.isPlayerViewActive = false
        XCTAssertTrue(vm.isNowPlayingBarVisible)

        vm.isPlayerViewActive = true
        XCTAssertFalse(vm.isNowPlayingBarVisible)

        vm.isPlayerViewActive = false
        XCTAssertTrue(vm.isNowPlayingBarVisible)
    }

    func test_applyPhase_sectioning_isDistinctFromQueuedAndStaleCleaning() {
        let vm = makeVM()
        vm.applyPhase(bookID: "b", phase: "cleaning", page: 10, total: 10)
        vm.applyPhase(bookID: "b", phase: "sectioning", page: 0, total: 0)

        XCTAssertNotEqual(vm.processingState["b"], .cleaning(page: 10, total: 10))
        XCTAssertNotEqual(vm.processingState["b"], .queued)
        XCTAssertEqual(vm.processingState["b"], .sectioning(page: 0, total: 0))
    }

    func test_applyStatus_doneAndTerminalStatesReplaceProcessingState() {
        let vm = makeVM()
        vm.applyStatus(bookID: "b", status: "tts", pageDone: 3, pageTotal: 10, error: nil)
        XCTAssertEqual(vm.processingState["b"], .generating(page: 3, total: 10))

        vm.applyStatus(bookID: "b", status: "failed", pageDone: 3, pageTotal: 10, error: "boom")
        XCTAssertEqual(vm.processingState["b"], .failed(reason: "boom"))

        vm.applyStatus(bookID: "b", status: "done", pageDone: 0, pageTotal: 0, error: nil)
        XCTAssertEqual(vm.processingState["b"], .ready)
    }

    func test_applyPhase_unknownPhaseLeavesStateUntouched() {
        let vm = makeVM()
        vm.applyPhase(bookID: "b", phase: "tts", page: 4, total: 10)
        vm.applyPhase(bookID: "b", phase: "mystery", page: 0, total: 0)
        XCTAssertEqual(vm.processingState["b"], .generating(page: 4, total: 10))
    }

    func test_fullProcessingLifecycle_neverFallsBackToAnEarlierPhaseOrQueued() {
        let vm = makeVM()
        let bookID = "book-lifecycle"
        var seen: [ProcessingStatus] = []

        for phase in ["extracting", "cleaning", "sectioning", "tts"] {
            vm.applyPhase(bookID: bookID, phase: phase, page: 0, total: 0)
            for page in 1 ... 10 {
                vm.applyPhase(bookID: bookID, phase: phase, page: page, total: 10)
                seen.append(vm.processingState[bookID] ?? .queued)
            }
        }
        XCTAssertFalse(seen.contains(.queued))
        XCTAssertEqual(vm.processingState[bookID], .generating(page: 10, total: 10))

        vm.applyPhase(bookID: bookID, phase: "concatenating", page: 0, total: 0)
        XCTAssertEqual(vm.processingState[bookID], .finishing)
        XCTAssertTrue(vm.processingState[bookID]?.isProcessing ?? false)

        vm.applyStatus(bookID: bookID, status: "done", pageDone: 0, pageTotal: 0, error: nil)
        XCTAssertEqual(vm.processingState[bookID], .ready)
    }

    func test_playDifferentBook_savesOutgoingPositionAndCancelsItsSleepTimer() {
        let vm = makeVM { _ in throw PlaybackFailure.unavailable }
        let bookA = makeBook(id: "book-a-\(UUID().uuidString)")
        let bookB = makeBook(id: "book-b-\(UUID().uuidString)")
        let positionKey = "bookPos_\(bookA.bookID)"
        defer { UserDefaults.standard.removeObject(forKey: positionKey) }

        vm.nowPlaying = bookA
        vm.audio.currentTime = 42.0
        vm.audio.duration = 600.0
        vm.audio.isPlaying = true
        vm.audio.playbackCompleted = false
        vm.startSleepTimer(.fifteenMinutes, currentBook: bookA)
        XCTAssertNotNil(vm.sleepTimerEndsAt)

        vm.play(bookB)

        XCTAssertEqual(UserDefaults.standard.double(forKey: positionKey), 42.0)
        XCTAssertNil(vm.sleepTimerEndsAt)
        XCTAssertNil(vm.nowPlaying)
    }

    func test_playFailureAfterLocalAudioResolves_doesNotCommitNowPlaying() async {
        let vm = makeVM { _ in
            FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).wav")
        }
        let priorLastPlayed = vm.lastPlayedBookID

        vm.play(makeBook(id: "book-corrupt-\(UUID().uuidString)"))
        await waitUntil { !vm.isLoadingAudio }

        XCTAssertFalse(vm.isLoadingAudio)
        XCTAssertNil(vm.nowPlaying)
        XCTAssertEqual(vm.lastPlayedBookID, priorLastPlayed)
        XCTAssertEqual(vm.toast?.kind, .error)
    }

    func test_stopPlaybackImmediatelyAfterPlay_preventsResurrection() async {
        let vm = makeVM { _ in
            FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).wav")
        }
        vm.play(makeBook(id: "book-race-\(UUID().uuidString)"))
        vm.stopPlayback()

        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(vm.nowPlaying)
        XCTAssertFalse(vm.isLoadingAudio)
        XCTAssertNil(vm.toast)
    }

    func test_cancelUpload_duringInFlightUpload_preventsStaleStateAfterCompletion() async throws {
        let vm = makeVM()
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try makeTempFile(named: "book.pdf", in: directory)

        vm.presentEstimate(for: document, voice: "af_bella", speed: 1.0, engine: "kokoro")
        XCTAssertEqual(vm.pendingDocument, document)
        XCTAssertTrue(vm.uploadInProgress)

        vm.cancelUpload()
        XCTAssertNil(vm.pendingDocument)
        XCTAssertNil(vm.pendingEstimate)
        XCTAssertFalse(vm.uploadInProgress)

        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertNil(vm.pendingDocument)
        XCTAssertNil(vm.pendingEstimate)
        XCTAssertNil(vm.loadingError)
        XCTAssertNil(vm.toast)
    }

    func test_cancelUpload_presentsTheNextQueuedDocument() throws {
        let vm = makeVM()
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try makeTempFile(named: "first.pdf", in: directory)
        let second = try makeTempFile(named: "second.pdf", in: directory)

        vm.presentEstimate(for: first, voice: "af_bella", speed: 1.0, engine: "kokoro")
        vm.presentEstimate(for: second, voice: "af_bella", speed: 1.0, engine: "kokoro")
        XCTAssertEqual(vm.queuedUploadCount, 1)

        vm.cancelUpload()

        XCTAssertEqual(vm.queuedUploadCount, 0)
        XCTAssertEqual(vm.pendingDocument, second)
        vm.cancelUpload()
    }

    func test_startProcessingFailure_stillFlushesQueuedUpload() async throws {
        let vm = makeVM()
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let queued = try makeTempFile(named: "queued.pdf", in: directory)

        vm.pendingDocument = try makeTempFile(named: "a.pdf", in: directory)
        vm.pendingEstimate = makeEstimate(bookID: "book-a-\(UUID().uuidString)")
        vm.presentEstimate(for: queued, voice: "af_bella", speed: 1.0, engine: "kokoro")
        XCTAssertEqual(vm.queuedUploadCount, 1)

        vm.startProcessing(useCleanup: false)
        await waitUntil { !vm.startingProcessing && vm.queuedUploadCount == 0 }

        XCTAssertEqual(vm.queuedUploadCount, 0)
        XCTAssertEqual(vm.pendingDocument, queued)
        vm.cancelUpload()
    }

    func test_dropOfSeveralFiles_importsEverySupportedFile() async throws {
        let vm = makeVM()
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try ["one.pdf", "two.txt", "three.md"].map { try makeTempFile(named: $0, in: directory) }
        let providers = urls.map { NSItemProvider(object: $0 as NSURL) }

        XCTAssertTrue(vm.importDroppedDocuments(providers, defaultVoice: "af_bella", defaultSpeed: 1.0))
        await waitUntil { vm.pendingDocument != nil && vm.queuedUploadCount == 2 }

        XCTAssertEqual(vm.pendingDocument?.lastPathComponent, "one.pdf")
        XCTAssertEqual(vm.queuedUploadCount, 2)
        vm.cancelUpload()
        vm.cancelUpload()
        vm.cancelUpload()
    }

    func test_dropMixingSupportedAndUnsupportedFiles_importsTheSupportedOnesAndWarnsOnce() async throws {
        let vm = makeVM()
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try ["photo.png", "one.pdf", "song.mp3", "two.docx"].map { try makeTempFile(named: $0, in: directory) }
        let providers = urls.map { NSItemProvider(object: $0 as NSURL) }

        XCTAssertTrue(vm.importDroppedDocuments(providers, defaultVoice: "af_bella", defaultSpeed: 1.0))
        await waitUntil { vm.pendingDocument != nil && vm.queuedUploadCount == 1 && vm.toast?.kind == .info
            && vm.toast?.message.contains("support") == true
        }

        XCTAssertEqual(vm.pendingDocument?.lastPathComponent, "one.pdf")
        XCTAssertEqual(vm.queuedUploadCount, 1)
        XCTAssertTrue(vm.toast?.message.contains(AudiobookImportStaging.supportedFormatsDescription) ?? false)
        vm.cancelUpload()
        vm.cancelUpload()
    }

    func test_dropWithoutFileProviders_isNotHandled() {
        let vm = makeVM()
        XCTAssertFalse(vm.importDroppedDocuments([], defaultVoice: "af_bella", defaultSpeed: 1.0))
        let textOnly = NSItemProvider(object: "hello" as NSString)
        XCTAssertFalse(vm.importDroppedDocuments([textOnly], defaultVoice: "af_bella", defaultSpeed: 1.0))
    }
}
