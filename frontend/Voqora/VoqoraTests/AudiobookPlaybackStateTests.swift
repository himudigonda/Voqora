@testable import Voqora
import XCTest

private enum DelayedAudioFailure: Error {
    case deliberatelyUnavailable
}

private enum LibraryLoadFailure: Error {
    case backendUnreachable
}

/// Crosses the `@Sendable` async list seam without capturing mutable local
/// state. This keeps the regression test honest under Swift 6 concurrency.
private actor LibraryLoadFailureSwitch {
    private var shouldFail = true

    func value() -> Bool {
        shouldFail
    }

    func clear() {
        shouldFail = false
    }
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

/// Generic ordering gate for T-8's overlapping-`refresh()` test: lets the
/// test hold one call's `listBooks()` open until it has confirmed a second,
/// faster call already resolved -- deterministic without a real network delay.
private actor ResolutionGate {
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var waitingWaiter: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
            waitingWaiter?.resume()
            waitingWaiter = nil
        }
    }

    func waitUntilWaiting() async {
        guard releaseWaiter == nil else { return }
        await withCheckedContinuation { continuation in
            waitingWaiter = continuation
        }
    }

    func release() {
        released = true
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

    // MARK: - stopPlayback(fadeOverSeconds:) — audiobook/global-speak interruption fix

    func test_stopPlayback_withFade_cancelsArmedSleepTimer() {
        // Regression: DashboardViewModel.speak() used to interrupt audiobook
        // playback via a raw `avm.audio.fadeOutAndStop(...)` + manual
        // `nowPlaying`/`currentTranscript` clear, bypassing stopPlayback()
        // entirely -- including cancelSleepTimer(). An armed sleep timer kept
        // running and later called audio.stop() on whatever became "the
        // shared audio" next (a new TTS clip, or a subsequently started
        // audiobook), silently killing it with no explanation. The fix adds
        // a `fadeOverSeconds` parameter to stopPlayback() itself so the
        // interruption path gets every other side effect for free.
        let viewModel = AudiobookViewModel(audio: AudioService(startingEngine: false))
        let book = makeBook(bookID: "b1", status: "done")
        viewModel.nowPlaying = book
        viewModel.startSleepTimer(.endOfBook, currentBook: book)
        XCTAssertTrue(viewModel.sleepUntilEndOfBook, "precondition: sleep timer armed")

        viewModel.stopPlayback(fadeOverSeconds: 0.12)

        XCTAssertFalse(
            viewModel.sleepUntilEndOfBook,
            "an interruption must cancel an armed sleep timer, not leave it running against whatever plays next"
        )
        XCTAssertNil(viewModel.sleepTimerEndsAt)
        XCTAssertNil(viewModel.nowPlaying, "interruption must still clear nowPlaying like a normal stop")
        XCTAssertNil(viewModel.currentTranscript)
    }

    func test_stopPlayback_defaultParameter_behavesExactlyAsBefore() {
        // The no-argument call site (Stop button, etc.) must be unaffected
        // by adding the optional fadeOverSeconds parameter.
        let viewModel = AudiobookViewModel(audio: AudioService(startingEngine: false))
        viewModel.nowPlaying = makeBook(bookID: "b1")

        viewModel.stopPlayback()

        XCTAssertNil(viewModel.nowPlaying)
        XCTAssertNil(viewModel.currentTranscript)
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

    // MARK: - sseTasks defer race (jira-audiobook-quality.md T-7)

    func test_subscribe_supersededSubscriptionCannotApplyEventsOrClearNewerRegistration() async {
        var continuationA: AsyncStream<[String: Any]>.Continuation!
        let streamA = AsyncStream<[String: Any]> { continuationA = $0 }
        var continuationB: AsyncStream<[String: Any]>.Continuation!
        let streamB = AsyncStream<[String: Any]> { continuationB = $0 }
        var callCount = 0
        let viewModel = AudiobookViewModel(
            audio: AudioService(startingEngine: false),
            subscribeToEvents: { _ in
                callCount += 1
                return callCount == 1 ? streamA : streamB
            }
        )

        // As startProcessing()/retry() do: subscribe twice in quick
        // succession for the same book. The first task's `defer` cleanup
        // (delayed since URLSession cancellation isn't instant) must not
        // fire before the second registration exists, nor clear it once it
        // does.
        viewModel.subscribe(to: "book1")
        try? await Task.sleep(nanoseconds: 10_000_000)
        viewModel.subscribe(to: "book1")
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertNotNil(viewModel.sseTasks["book1"], "a live registration must exist after the second subscribe()")

        // A stale event from the superseded (first) stream must be ignored.
        continuationA.yield([
            "type": "snapshot", "status": "cleaning",
            "phase_progress": ["page_done": 1, "page_total": 10],
        ])
        try? await Task.sleep(nanoseconds: 15_000_000)
        XCTAssertNil(
            viewModel.processingState["book1"],
            "the superseded subscription must not be able to apply events"
        )

        // The current (second) subscription's event must still apply.
        continuationB.yield([
            "type": "snapshot", "status": "cleaning",
            "phase_progress": ["page_done": 5, "page_total": 10],
        ])
        try? await Task.sleep(nanoseconds: 15_000_000)
        guard case let .cleaning(page, total) = viewModel.processingState["book1"] else {
            XCTFail("expected the current subscription's event to apply, got \(String(describing: viewModel.processingState["book1"]))")
            return
        }
        XCTAssertEqual(page, 5)
        XCTAssertEqual(total, 10)

        // Finishing the now-superseded first stream (its `defer` firing late)
        // must not wipe out the still-live second registration.
        continuationA.finish()
        try? await Task.sleep(nanoseconds: 15_000_000)
        XCTAssertNotNil(viewModel.sseTasks["book1"], "an older task's deferred cleanup must not clear a newer registration")

        continuationB.finish()
    }

    // MARK: - processingState / completionSummary race guards (jira-audiobook-quality.md T-8)

    func test_refresh_doesNotOverwriteProcessingState_forBookWithActiveSSE() async {
        let book = makeBook(bookID: "b1", status: "cleaning", pageDone: 1, pageTotal: 10)
        let viewModel = AudiobookViewModel(
            audio: AudioService(startingEngine: false),
            subscribeToEvents: { _ in AsyncStream { _ in } }, // never yields; stays "active"
            listBooks: { [book] }
        )
        viewModel.subscribe(to: "b1")
        try? await Task.sleep(nanoseconds: 10_000_000)
        // SSE already advanced this book further than the GET snapshot knows about.
        viewModel.processingState["b1"] = .generating(page: 9, total: 10)

        await viewModel.refresh()

        guard case let .generating(page, total) = viewModel.processingState["b1"] else {
            XCTFail("SSE-owned state must survive a poll refresh, got \(String(describing: viewModel.processingState["b1"]))")
            return
        }
        XCTAssertEqual(page, 9)
        XCTAssertEqual(total, 10)
    }

    func test_refresh_overlappingCalls_onlyNewerGenerationApplies() async {
        let staleBook = makeBook(bookID: "b1", status: "cleaning", pageDone: 1, pageTotal: 10)
        let freshBook = makeBook(bookID: "b1", status: "cleaning", pageDone: 5, pageTotal: 10)
        let gate = ResolutionGate()
        var callCount = 0
        let viewModel = AudiobookViewModel(
            audio: AudioService(startingEngine: false),
            subscribeToEvents: { _ in AsyncStream { _ in } },
            listBooks: {
                callCount += 1
                if callCount == 1 {
                    await gate.waitForRelease() // first call: held open
                    return [staleBook]
                }
                return [freshBook] // second call: resolves immediately
            }
        )

        let firstRefresh = Task { await viewModel.refresh() }
        await gate.waitUntilWaiting()
        let secondRefresh = Task { await viewModel.refresh() }
        await secondRefresh.value
        await gate.release()
        await firstRefresh.value

        guard case let .cleaning(page, _) = viewModel.processingState["b1"] else {
            XCTFail("expected .cleaning, got \(String(describing: viewModel.processingState["b1"]))")
            return
        }
        XCTAssertEqual(page, 5, "the older, later-resolving refresh must not overwrite the newer one's result")
    }

    func test_applyCompletion_receiptOrderWins_notResolutionOrder() {
        let viewModel = AudiobookViewModel(audio: AudioService(startingEngine: false))
        let bookA = makeBook(bookID: "A", status: "done")
        let bookB = makeBook(bookID: "B", status: "done")

        // A's "done" event is received first, B's second -- but A's fetch
        // resolves *after* B's (simulating a slower fetchDetailWithFallback).
        let generationA = viewModel.beginCompletionFetch()
        let generationB = viewModel.beginCompletionFetch()

        viewModel.applyCompletion(bookB, generation: generationB) // resolves first
        viewModel.applyCompletion(bookA, generation: generationA) // resolves later, but stale

        XCTAssertEqual(
            viewModel.completionSummary?.bookID, "B",
            "completionSummary must reflect the event received last (B), not whichever fetch resolved last (A)"
        )
    }

    // MARK: - delete() cancels its SSE task (jira-audiobook-quality.md T-9)

    func test_delete_cancelsAndRemovesSSETask_lateEventIsNoOp() async {
        var continuation: AsyncStream<[String: Any]>.Continuation!
        let stream = AsyncStream<[String: Any]> { continuation = $0 }
        let book = makeBook(bookID: "b1", status: "cleaning")
        let viewModel = AudiobookViewModel(
            audio: AudioService(startingEngine: false),
            subscribeToEvents: { _ in stream }
        )

        viewModel.subscribe(to: "b1")
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertNotNil(viewModel.sseTasks["b1"], "precondition: an active SSE task exists before delete()")

        viewModel.delete(book)
        // sseTasks/sseGeneration are cleared synchronously by delete(), ahead
        // of its async network-delete Task -- no need to wait for that here.
        XCTAssertNil(viewModel.sseTasks["b1"], "delete() must cancel and remove the book's SSE task")

        // A late event, arriving after delete(), must be a no-op.
        continuation.yield([
            "type": "snapshot", "status": "cleaning",
            "phase_progress": ["page_done": 3, "page_total": 10],
        ])
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(
            viewModel.processingState["b1"],
            "a late SSE event after delete() must not resurrect processingState"
        )
        continuation.finish()
    }

    // MARK: - completion-mis-attribution mitigation (jira-audiobook-quality.md T-10)

    func test_completionObserver_attributesToTheSessionThatCompleted_notCurrentNowPlaying() {
        let bookPosKeyA = "bookPos_t10-book-a"
        let bookPosKeyB = "bookPos_t10-book-b"
        UserDefaults.standard.removeObject(forKey: bookPosKeyA)
        UserDefaults.standard.removeObject(forKey: bookPosKeyB)
        defer {
            UserDefaults.standard.removeObject(forKey: bookPosKeyA)
            UserDefaults.standard.removeObject(forKey: bookPosKeyB)
        }

        let audio = AudioService(startingEngine: false)
        let viewModel = AudiobookViewModel(audio: audio)
        UserDefaults.standard.set(42.0, forKey: bookPosKeyA)
        UserDefaults.standard.set(7.0, forKey: bookPosKeyB)

        // Simulate: book A's natural-completion signal was scheduled with A's
        // identity captured (AudioService's own internal step, mirrored here
        // by setting completedSessionID directly)...
        audio.completedSessionID = "t10-book-a"
        // ...but by the time the sink actually observes it, the user has
        // already started book B -- nowPlaying has moved on.
        viewModel.nowPlaying = makeBook(bookID: "t10-book-b")

        audio.playbackCompleted = true

        XCTAssertNil(
            UserDefaults.standard.object(forKey: bookPosKeyA),
            "the session that actually completed (A) must have its resume position cleared"
        )
        XCTAssertEqual(
            UserDefaults.standard.double(forKey: bookPosKeyB), 7.0,
            "book B's resume position must be untouched -- it did not complete"
        )
    }

    // MARK: - Distinct library-load-failure state (jira-audiobook-quality.md T-17)

    func test_refresh_catchPath_setsLoadFailedFlag() async {
        let viewModel = AudiobookViewModel(
            audio: AudioService(startingEngine: false),
            listBooks: { throw LibraryLoadFailure.backendUnreachable }
        )
        XCTAssertFalse(viewModel.loadFailed, "precondition: no failure yet")

        await viewModel.refresh()

        XCTAssertTrue(viewModel.loadFailed, "a failed refresh() must set a distinguishable flag")
        XCTAssertTrue(viewModel.hasLoadedOnce)
        XCTAssertNotNil(viewModel.toast, "the existing transient toast must still fire")
    }

    func test_refresh_clearsLoadFailedFlag_onNextSuccess() async {
        let failureSwitch = LibraryLoadFailureSwitch()
        let book = makeBook(bookID: "b1", status: "done")
        let viewModel = AudiobookViewModel(
            audio: AudioService(startingEngine: false),
            subscribeToEvents: { _ in AsyncStream { _ in } },
            listBooks: {
                if await failureSwitch.value() {
                    throw LibraryLoadFailure.backendUnreachable
                }
                return [book]
            }
        )

        await viewModel.refresh()
        XCTAssertTrue(viewModel.loadFailed)

        await failureSwitch.clear()
        await viewModel.refresh()

        XCTAssertFalse(viewModel.loadFailed, "a subsequent successful refresh() must clear the flag")
    }

    // MARK: - "sectioning" status gap (jira-audiobook-quality.md T-6)

    func test_displayStatus_sectioning_returnsDistinctCase_notQueued() {
        let book = makeBook(status: "sectioning", pageDone: 3, pageTotal: 10)
        guard case let .sectioning(page, total) = book.displayStatus else {
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
        guard case let .sectioning(page, total) = viewModel.processingState["b1"] else {
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
        guard case let .sectioning(page, total) = viewModel.processingState["b1"] else {
            XCTFail(
                "applyPhase(sectioning) must not silently no-op and leave the prior phase's " +
                    "state frozen, got \(String(describing: viewModel.processingState["b1"]))"
            )
            return
        }
        XCTAssertEqual(page, 5)
        XCTAssertEqual(total, 5)
    }

    func test_displayStatus_costApprovalCarriesPersistedAbsoluteCap() {
        let approval = GeminiBudget.CostApproval(
            requiredCapUsd: 2.75,
            currentCapUsd: 1.00,
            tier: "standard"
        )
        let book = makeBook(
            status: "needs_cost_approval",
            budget: GeminiBudget(capUsd: 1, actualUsd: 0.4, reservedUsd: 0.6, costApproval: approval)
        )

        guard case let .needsCostApproval(requiredCap) = book.displayStatus else {
            XCTFail("expected cost approval state, got \(book.displayStatus)")
            return
        }
        XCTAssertEqual(requiredCap, 2.75)
        XCTAssertFalse(book.displayStatus.isProcessing)
    }

    private func makeBook(
        bookID: String = "in-flight-book",
        status: String = "done",
        pageDone: Int = 1,
        pageTotal: Int = 1,
        budget: GeminiBudget? = nil
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
            budget: budget,
            error: nil
        )
    }
}
