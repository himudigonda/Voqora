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

    private func makeBook() -> Audiobook {
        Audiobook(
            bookID: "in-flight-book",
            title: "In-flight book",
            createdAt: "2026-07-30T00:00:00Z",
            pageCount: 1,
            status: "done",
            phaseProgress: PhaseProgress(pageDone: 1, pageTotal: 1),
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
