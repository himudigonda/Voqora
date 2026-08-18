@testable import Voqora
import XCTest

private enum DelayedAudioFailure: Error {
    case deliberatelyUnavailable
}

private actor DelayedAudioLoader {
    private var requested = false
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func load() async throws -> URL {
        requested = true
        requestWaiter?.resume()
        requestWaiter = nil
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
        throw DelayedAudioFailure.deliberatelyUnavailable
    }

    func waitUntilRequested() async {
        guard !requested else { return }
        await withCheckedContinuation { continuation in
            requestWaiter = continuation
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
final class AudiobookPlaybackStateTests: XCTestCase {
    func test_nowPlayingBar_isVisibleOnlyOutsideFullPlayer() {
        let viewModel = AudiobookViewModel(audio: AudioService(startingEngine: false))
        XCTAssertFalse(viewModel.isNowPlayingBarVisible)

        viewModel.nowPlaying = makeBook()
        XCTAssertTrue(viewModel.isNowPlayingBarVisible)

        viewModel.isPlayerViewActive = true
        XCTAssertFalse(
            viewModel.isNowPlayingBarVisible,
            "The compact player must not render beneath the full audiobook player."
        )

        viewModel.isPlayerViewActive = false
        XCTAssertTrue(viewModel.isNowPlayingBarVisible)
    }

    func test_stopInvalidatesAnyInFlightBookLoad() async {
        let audio = AudioService(startingEngine: false)
        let loader = DelayedAudioLoader()
        let viewModel = AudiobookViewModel(
            audio: audio,
            localAudioURL: { _ in try await loader.load() }
        )
        let before = viewModel.playbackGeneration

        viewModel.play(makeBook())
        await loader.waitUntilRequested()
        XCTAssertTrue(viewModel.isLoadingAudio)
        XCTAssertTrue(viewModel.isPreparingPlayback)

        viewModel.stopPlayback()
        await loader.release()
        try? await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertGreaterThan(viewModel.playbackGeneration, before)
        XCTAssertFalse(viewModel.isLoadingAudio)
        XCTAssertFalse(viewModel.isPreparingPlayback)
        XCTAssertNil(viewModel.nowPlaying)
        XCTAssertNil(viewModel.toast)
        XCTAssertFalse(audio.isPlaying)
    }

    // MARK: - libraryPollInterval (jira-cpu-ram-optimization.md T-6)

    func test_libraryPollInterval_foreground_matchesExistingSSECadence() {
        XCTAssertEqual(
            AudiobookViewModel.libraryPollInterval(hasActiveSSE: false, isBackgrounded: false),
            5_000_000_000
        )
        XCTAssertEqual(
            AudiobookViewModel.libraryPollInterval(hasActiveSSE: true, isBackgrounded: false),
            15_000_000_000
        )
    }

    func test_libraryPollInterval_backgrounded_widensToSixtySecondFloor() {
        XCTAssertEqual(
            AudiobookViewModel.libraryPollInterval(hasActiveSSE: false, isBackgrounded: true),
            60_000_000_000
        )
        XCTAssertEqual(
            AudiobookViewModel.libraryPollInterval(hasActiveSSE: true, isBackgrounded: true),
            60_000_000_000
        )
    }

    // MARK: - "sectioning" status gap (jira-audiobook-quality.md T-6)

    func test_displayStatus_sectioning_returnsDistinctCase_notQueued() {
        let book = makeBook(status: "sectioning", pageDone: 3, pageTotal: 10)
        guard case .sectioning(let page, let total) = book.displayStatus else {
            XCTFail("expected .sectioning, got \(book.displayStatus)")
            return
        }
        XCTAssertEqual(page, 3)
        XCTAssertEqual(total, 10)
        XCTAssertTrue(book.displayStatus.isProcessing)
    }

    func test_applyStatus_sectioning_setsSectioningState() {
        let viewModel = AudiobookViewModel(audio: AudioService(startingEngine: false))
        viewModel.applyStatus(bookID: "b1", status: "sectioning", pageDone: 2, pageTotal: 5, error: nil)
        guard case .sectioning(let page, let total) = viewModel.processingState["b1"] else {
            XCTFail("expected .sectioning, got \(String(describing: viewModel.processingState["b1"]))")
            return
        }
        XCTAssertEqual(page, 2)
        XCTAssertEqual(total, 5)
    }

    func test_applyPhase_sectioning_setsSectioningState_doesNotFreezeAtPriorPhase() {
        let viewModel = AudiobookViewModel(audio: AudioService(startingEngine: false))
        viewModel.applyPhase(bookID: "b1", phase: "cleaning", page: 1, total: 5)
        viewModel.applyPhase(bookID: "b1", phase: "sectioning", page: 5, total: 5)
        guard case .sectioning(let page, let total) = viewModel.processingState["b1"] else {
            XCTFail(
                "applyPhase(sectioning) must not silently no-op and leave the prior phase's " +
                "state frozen, got \(String(describing: viewModel.processingState["b1"]))"
            )
            return
        }
        XCTAssertEqual(page, 5)
        XCTAssertEqual(total, 5)
    }

    private func makeBook(
        bookID: String = "in-flight-book",
        status: String = "done",
        pageDone: Int = 1,
        pageTotal: Int = 1
    ) -> Audiobook {
        Audiobook(
            bookID: bookID,
            title: "In-flight book",
            createdAt: "2026-07-30T00:00:00Z",
            pageCount: 1,
            status: status,
            phaseProgress: PhaseProgress(pageDone: pageDone, pageTotal: pageTotal),
            sections: [],
            pageToTime: [:],
            totalAudioSeconds: 0,
            failedPages: [],
            estimated: nil,
            actual: nil,
            engine: "kokoro",
            voice: "af_bella",
            speed: 1,
            usesGeminiCleanup: false,
            error: nil
        )
    }
}
