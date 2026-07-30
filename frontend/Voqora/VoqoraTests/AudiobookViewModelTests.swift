@testable import Voqora
import XCTest

/// AudiobookViewModel state-toggle tests (the v1.1 design notes Sprint 6, T6.1).
///
/// `isPlayerViewActive` / `isNowPlayingBarVisible` are the fix for Defect A:
/// NowPlayingBar previously rendered underneath AudiobookPlayerView nearly
/// always, because opening the player calls `play()`, which makes
/// `nowPlaying` non-nil for the entire time the player is on screen — the
/// bar's old gate (`nowPlaying != nil` alone) couldn't distinguish "a book
/// is playing" from "that book's own player is already open."
///
/// These tests cover the pure state-toggle logic (the part that's actually
/// unit-testable). The SwiftUI onAppear/onDisappear wiring in
/// AudiobookPlayerView, and the live no-ghosting/reappearance behavior in
/// the running app, are manual/visual-verification only — see the Sprint 6
/// completion note.
@MainActor
final class AudiobookViewModelTests: XCTestCase {
    /// A deliberately open stream for subscription-lifecycle tests. It keeps
    /// the test off the real loopback backend while preserving the same
    /// cancellation semantics as a production SSE stream.
    private final class HeldEventStreams {
        private var continuations: [AsyncStream<[String: Any]>.Continuation] = []

        func stream(for _: String) -> AsyncStream<[String: Any]> {
            AsyncStream { continuation in
                continuations.append(continuation)
            }
        }

        deinit {
            continuations.forEach { $0.finish() }
        }
    }

    private func makeVM() -> AudiobookViewModel {
        AudiobookViewModel(audio: AudioService())
    }

    private func makeBook(id: String = "book-1") -> Audiobook {
        Audiobook(
            bookID: id,
            title: "Test Book.pdf",
            createdAt: "2026-01-01T00:00:00Z",
            pageCount: 10,
            status: "done",
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
            error: nil
        )
    }

    // MARK: - Defaults

    func test_isPlayerViewActive_defaultsFalse() {
        let vm = makeVM()
        XCTAssertFalse(vm.isPlayerViewActive)
    }

    func test_isNowPlayingBarVisible_falseWhenNothingPlaying() {
        let vm = makeVM()
        XCTAssertNil(vm.nowPlaying)
        XCTAssertFalse(vm.isNowPlayingBarVisible)
    }

    // MARK: - The four-state truth table

    func test_isNowPlayingBarVisible_trueWhenPlayingAndPlayerNotActive() {
        let vm = makeVM()
        vm.nowPlaying = makeBook()
        vm.isPlayerViewActive = false
        XCTAssertTrue(vm.isNowPlayingBarVisible)
    }

    func test_isNowPlayingBarVisible_falseWhenPlayingAndPlayerActive() {
        // The exact Defect A scenario: opening the player for the book
        // that's already playing must NOT show the duplicate bar.
        let vm = makeVM()
        vm.nowPlaying = makeBook()
        vm.isPlayerViewActive = true
        XCTAssertFalse(vm.isNowPlayingBarVisible)
    }

    func test_isNowPlayingBarVisible_falseWhenNotPlayingRegardlessOfPlayerFlag() {
        let vm = makeVM()
        vm.nowPlaying = nil
        vm.isPlayerViewActive = true
        XCTAssertFalse(vm.isNowPlayingBarVisible)

        vm.isPlayerViewActive = false
        XCTAssertFalse(vm.isNowPlayingBarVisible)
    }

    // MARK: - Reappearance after leaving the player

    func test_isNowPlayingBarVisible_reappearsAfterLeavingPlayerWhileStillPlaying() {
        // Mirrors "navigate back to the library while playing" from
        // the v1.1 design notes T6.1's verify step: nowPlaying stays constant throughout,
        // only the player-active flag changes.
        let vm = makeVM()
        vm.nowPlaying = makeBook()
        vm.isPlayerViewActive = true
        XCTAssertFalse(vm.isNowPlayingBarVisible)

        vm.isPlayerViewActive = false
        XCTAssertTrue(vm.isNowPlayingBarVisible)
    }

    // MARK: - the v1.1 design notes Sprint 4 (D5/E9): "sectioning"/"concatenating" progress

    /// `applyStatus`/`applyPhase` are `internal` (not `private`) specifically
    /// so these tests can drive them directly via `@testable import` — see
    /// their doc comments in AudiobookViewModel.swift for why (no HTTP/SSE
    /// mocking seam exists for the `final class AudiobookService`).

    func test_applyPhase_sectioning_isDistinctFromQueuedAndFromStaleClean() {
        let vm = makeVM()
        let bookID = "book-sectioning"

        // Real backend sequence: cleaning completes at 10/10, then
        // "sectioning" starts with no page/total at all
        // (audiobook_service.py:531).
        vm.applyPhase(bookID: bookID, phase: "cleaning", page: 10, total: 10)
        vm.applyPhase(bookID: bookID, phase: "sectioning", page: 0, total: 0)

        // Pre-fix: "sectioning" had no case, hit `default: return` — a
        // silent no-op that left the stale .cleaning(10, 10) state in place.
        XCTAssertNotEqual(vm.processingState[bookID], .cleaning(page: 10, total: 10))
        // Also must not be generic/false-complete QUEUED (the D5 sibling bug).
        XCTAssertNotEqual(vm.processingState[bookID], .queued)
        XCTAssertEqual(vm.processingState[bookID], .sectioning)
    }

    func test_applyStatus_sectioning_isNotQueued() {
        let vm = makeVM()
        vm.applyStatus(bookID: "book-snapshot", status: "sectioning", pageDone: 10, pageTotal: 10, error: nil)
        XCTAssertEqual(vm.processingState["book-snapshot"], .sectioning)
    }

    func test_applyStatus_concatenating_alwaysShowsFullProgress() {
        let vm = makeVM()
        // Mirrors Audiobook.displayStatus's own convention: "concatenating"
        // always renders as fully complete, regardless of whatever
        // pageDone the snapshot happens to carry.
        vm.applyStatus(bookID: "book-snapshot-2", status: "concatenating", pageDone: 7, pageTotal: 10, error: nil)
        XCTAssertEqual(vm.processingState["book-snapshot-2"], .generating(page: 10, total: 10))
    }

    /// The core E9 regression guard: `applyPhase`'s "concatenating" case
    /// carries no page/total (backend's `_emit` call at
    /// audiobook_service.py:989 passes neither), so applying it naively
    /// overwrote the just-completed 100% tts progress with
    /// `.generating(page: 0, total: 0)` — visibly, reproducibly, every time
    /// a book finished processing.
    func test_applyPhase_concatenating_doesNotRegressCompletedTtsProgress() {
        let vm = makeVM()
        let bookID = "book-concat"

        vm.applyPhase(bookID: bookID, phase: "tts", page: 10, total: 10)
        XCTAssertEqual(vm.processingState[bookID], .generating(page: 10, total: 10))

        // The exact regression trigger: concatenating's phase_started event,
        // page/total both defaulted to 0.
        vm.applyPhase(bookID: bookID, phase: "concatenating", page: 0, total: 0)

        XCTAssertNotEqual(
            vm.processingState[bookID], .generating(page: 0, total: 0),
            "E9 regression: concatenating's phase_started must not zero out tts's completed progress"
        )
        XCTAssertEqual(vm.processingState[bookID], .generating(page: 10, total: 10))
    }

    /// Pins down the degenerate fallback branch of `applyPhase`'s
    /// "concatenating" case: a fresh subscribe with no prior
    /// `processingState` entry at all for this book (e.g. a reconnect that
    /// happens to land exactly on a "concatenating" `phase_started` event)
    /// has no prior total to preserve, so it falls back to whatever the
    /// event itself carries. Not reachable in normal operation (every real
    /// subscribe path seeds `processingState` from `book.displayStatus`
    /// first), but this documents the intentional behavior rather than
    /// leaving it untested.
    func test_applyPhase_concatenating_withNoPriorState_fallsBackToEventTotal() {
        let vm = makeVM()
        vm.applyPhase(bookID: "book-fresh-concat", phase: "concatenating", page: 0, total: 0)
        XCTAssertEqual(vm.processingState["book-fresh-concat"], .generating(page: 0, total: 0))
    }

    /// Drives the full, realistic per-book event sequence end-to-end
    /// (the v1.1 design notes T4.2's verify step) and asserts progress is monotonically
    /// sensible throughout — it never drops to a lower "completeness" than
    /// a prior phase already implied.
    func test_fullProcessingLifecycle_progressNeverRegresses() {
        let vm = makeVM()
        let bookID = "book-lifecycle"

        // extracting: phase_started (0/0), then page_done 1/10 ... 10/10.
        vm.applyPhase(bookID: bookID, phase: "extracting", page: 0, total: 0)
        for page in 1 ... 10 {
            vm.applyPhase(bookID: bookID, phase: "extracting", page: page, total: 10)
        }
        XCTAssertEqual(vm.processingState[bookID], .extracting(page: 10, total: 10))

        // cleaning: phase_started (0/0), then page_done 1/10 ... 10/10.
        vm.applyPhase(bookID: bookID, phase: "cleaning", page: 0, total: 0)
        for page in 1 ... 10 {
            vm.applyPhase(bookID: bookID, phase: "cleaning", page: page, total: 10)
        }
        XCTAssertEqual(vm.processingState[bookID], .cleaning(page: 10, total: 10))

        // sectioning: phase_started carries no page/total at all (real
        // backend behavior) — must land on the distinct .sectioning state,
        // not regress to .generating(0, 0) and not silently freeze on the
        // stale .cleaning(10, 10) state (the D5/E9 bug).
        vm.applyPhase(bookID: bookID, phase: "sectioning", page: 0, total: 0)
        XCTAssertEqual(vm.processingState[bookID], .sectioning)

        // tts: phase_started (0/0), then page_done 1/10 ... 10/10.
        vm.applyPhase(bookID: bookID, phase: "tts", page: 0, total: 0)
        for page in 1 ... 10 {
            vm.applyPhase(bookID: bookID, phase: "tts", page: page, total: 10)
        }
        XCTAssertEqual(vm.processingState[bookID], .generating(page: 10, total: 10))

        // concatenating: phase_started carries no page/total either (real
        // backend behavior) — this is the exact E9 regression: pre-fix, this
        // overwrote the just-completed 100% tts progress with
        // .generating(page: 0, total: 0).
        vm.applyPhase(bookID: bookID, phase: "concatenating", page: 0, total: 0)
        XCTAssertEqual(
            vm.processingState[bookID], .generating(page: 10, total: 10),
            "progress must not regress backward entering concatenating"
        )

        // done.
        vm.applyStatus(bookID: bookID, status: "done", pageDone: 0, pageTotal: 0, error: nil)
        XCTAssertEqual(vm.processingState[bookID], .ready)
    }

    // MARK: - the v1.1 design notes Sprint 7 — frontend pipeline correctness fixes (Finding Set E)

    /// Builds a minimal, genuinely valid 16-bit mono PCM WAV file (mirroring
    /// `AudioService.exportToDesktop()`'s own header format) so
    /// `AVAudioFile(forReading:)`/`loadAndPlayWAV()` can actually open and
    /// play it. Used by tests that need `ensureLocalAudio` AND
    /// `loadAndPlayWAV` to both genuinely succeed (T7.3), as opposed to
    /// T7.2's test, which deliberately wants `loadAndPlayWAV` to fail.
    private func makeValidWAVData(seconds: Double = 0.2) -> Data {
        let sampleRate: UInt32 = 24000
        let sampleCount = Int(seconds * Double(sampleRate))
        let pcmData = Data(count: sampleCount * 2) // 16-bit mono silence
        let headerSize = 44
        let totalSize = UInt32(pcmData.count + headerSize - 8)
        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: totalSize) { Data($0) })
        header.append("WAVEfmt ".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16)) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1)) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1)) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2)) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(2)) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(16)) { Data($0) })
        header.append("data".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(pcmData.count)) { Data($0) })
        return header + pcmData
    }

    // MARK: - T7.1/E1: play() switching books routes through stopPlayback()

    func test_playDifferentBook_savesOutgoingPositionAndCancelsItsSleepTimer() {
        let vm = makeVM()
        let bookA = makeBook(id: "book-a-\(UUID().uuidString)")
        let bookB = makeBook(id: "book-b-\(UUID().uuidString)")
        defer { UserDefaults.standard.removeObject(forKey: "bookPos_\(bookA.bookID)") }

        // Simulate "book A is already playing" directly via AudioService's
        // settable @Published properties — no real audio file needed for
        // this assertion, which only depends on stopPlayback()'s teardown.
        vm.nowPlaying = bookA
        vm.audio.currentTime = 42.0
        vm.audio.duration = 600.0
        vm.audio.isPlaying = true
        vm.audio.playbackCompleted = false

        vm.startSleepTimer(.fifteenMinutes, currentBook: bookA)
        XCTAssertNotNil(vm.sleepTimerEndsAt, "test setup: sleep timer should be armed for book A")

        // stopPlayback()'s teardown runs synchronously inside play(), before
        // the async network fetch — no need to await anything here.
        vm.play(bookB)

        XCTAssertEqual(
            UserDefaults.standard.double(forKey: "bookPos_\(bookA.bookID)"), 42.0,
            "E1: switching books must save the outgoing book's position, same as an explicit stop"
        )
        XCTAssertNil(vm.sleepTimerEndsAt, "E1: switching books must cancel any sleep timer armed for the outgoing book")
    }

    // MARK: - T7.2/E2: nowPlaying only commits after loadAndPlayWAV succeeds

    func test_playFailureAfterEnsureLocalAudioSucceeds_doesNotCommitNowPlaying() async {
        let service = AudiobookService()
        let bookID = "book-corrupt-wav-\(UUID().uuidString)"
        let cacheURL = service.localCachedAudioURL(for: bookID)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        // Seeds the cache with a file that passes AudiobookService's own
        // shallow "is this a WAV" header check (RIFF....WAVE) — so
        // ensureLocalAudio short-circuits with no network call — but has no
        // real fmt/data chunks, so AudioService.loadAndPlayWAV()'s real
        // AVAudioFile(forReading:) parse genuinely throws on it. Exercises
        // the real E2 regression without mocking either type —
        // AudiobookService has no protocol seam to substitute (see
        // applyStatus's doc comment).
        var corruptWAV = Data("RIFF".utf8)
        corruptWAV.append(contentsOf: [0, 0, 0, 0]) // bogus chunk size, no real fmt/data after
        corruptWAV.append(Data("WAVE".utf8))
        try? corruptWAV.write(to: cacheURL)

        let vm = AudiobookViewModel(service: service, audio: AudioService())
        let book = makeBook(id: bookID)
        let priorNowPlaying = vm.nowPlaying
        let priorLastPlayed = vm.lastPlayedBookID

        vm.play(book)
        for _ in 0 ..< 40 {
            if !vm.isLoadingAudio { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(vm.nowPlaying, priorNowPlaying, "E2: a loadAndPlayWAV throw must not leave nowPlaying pointing at a book with no audio loaded")
        XCTAssertEqual(vm.lastPlayedBookID, priorLastPlayed, "E2: lastPlayedBookID must not commit either when loadAndPlayWAV throws")
    }

    // MARK: - T7.3/E3: stopPlayback() racing an in-flight play()

    func test_stopPlaybackDuringInFlightPlay_preventsResurrection() async {
        let service = AudiobookService()
        let bookID = "book-race-\(UUID().uuidString)"
        let cacheURL = service.localCachedAudioURL(for: bookID)
        try? makeValidWAVData().write(to: cacheURL)
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let vm = AudiobookViewModel(service: service, audio: AudioService())
        let book = makeBook(id: bookID)

        // ensureLocalAudio finds the pre-seeded cache (no network), and
        // loadAndPlayWAV can genuinely succeed on it — so, pre-fix, the
        // in-flight Task really would reach `nowPlaying = book`. Swift's
        // cooperative scheduling guarantees the newly-created play() Task
        // cannot start running until this synchronous stretch (play() then
        // stopPlayback(), with no `await` between them) yields — so
        // stopPlayback() always wins the race deterministically, not by luck.
        vm.play(book)
        vm.stopPlayback()

        for _ in 0 ..< 40 {
            if !vm.isLoadingAudio { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNil(vm.nowPlaying, "E3: stopPlayback() racing an in-flight play() must prevent it from later resurrecting playback")
    }

    // MARK: - T7.6/E6: cancelUpload() invalidates an in-flight upload

    func test_cancelUpload_duringInFlightUpload_preventsStaleStateAfterCompletion() async {
        let vm = makeVM()
        // A path that doesn't exist — service.upload()'s `try
        // Data(contentsOf: pdf)` throws synchronously, giving a fast,
        // deterministic "upload settles after cancellation" without
        // depending on network timing or a live backend.
        let bogusPDF = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).pdf")

        vm.presentEstimate(for: bogusPDF, voice: "af_bella", speed: 1.0, engine: "kokoro")
        XCTAssertEqual(vm.pendingPDF, bogusPDF)

        // Dismiss immediately — no `await` has happened on this actor since
        // presentEstimate returned, so the upload Task's body hasn't started.
        vm.cancelUpload()
        XCTAssertNil(vm.pendingPDF)
        XCTAssertNil(vm.pendingEstimate)

        for _ in 0 ..< 40 {
            if !vm.uploadInProgress { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNil(vm.pendingPDF, "E6: a late-settling upload must not resurrect pendingPDF after the modal was dismissed")
        XCTAssertNil(vm.pendingEstimate, "E6: a late-settling upload must not resurrect pendingEstimate after the modal was dismissed")
        XCTAssertNil(vm.toast, "E6: a cancelled upload's own (now-irrelevant) failure must not surface a stray toast")
    }

    // MARK: - T7.7/E7: startProcessing() failure still flushes the queue

    func test_startProcessingFailure_stillFlushesQueuedUpload() async {
        let vm = makeVM()
        let bookA = "book-a-\(UUID().uuidString)"
        let fileB = FileManager.default.temporaryDirectory.appendingPathComponent("queued-b-\(UUID().uuidString).pdf")

        // Simulate "book A's estimate modal is up" without a real upload.
        vm.pendingPDF = FileManager.default.temporaryDirectory.appendingPathComponent("a.pdf")
        vm.pendingEstimate = AudiobookEstimateResponse(
            bookID: bookA, title: "A", pageCount: 1, wordCountEstimate: 1,
            estimatedProcessingSeconds: 1, estimatedAudioSeconds: 1, estimatedCostUsd: 0,
            estimatedTokenCount: 1, isImageOnly: false, costWarning: false
        )

        // Drop file B while A's modal is up — queues it via the real
        // (unmodified) queueing branch of presentEstimate, no network involved.
        vm.presentEstimate(for: fileB, voice: "af_bella", speed: 1.0, engine: "kokoro")
        XCTAssertEqual(vm.queuedUploadCount, 1)

        // startProcessing needs a Gemini key present to even attempt the
        // network call — save/restore whatever was really there.
        let priorKey = KeychainService.get(.geminiAPIKey)
        KeychainService.set("test-fake-key", for: .geminiAPIKey)
        defer {
            if let priorKey {
                KeychainService.set(priorKey, for: .geminiAPIKey)
            } else {
                KeychainService.delete(.geminiAPIKey)
            }
        }

        vm.startProcessing(consent: true)
        // Book A was never really uploaded, so /start fails (404 against a
        // live backend, or a connection error with none running) — either
        // way it throws, exercising the catch branch.
        for _ in 0 ..< 60 {
            if !vm.startingProcessing { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertNotNil(vm.toast, "expected /start to fail for a fabricated book id, exercising startProcessing()'s catch branch")
        XCTAssertEqual(
            vm.queuedUploadCount, 0,
            "E7: startProcessing()'s failure branch must flush the queue, like the success branch already does"
        )
    }

    // MARK: - T7.8/E8: double-subscribe doesn't desync the sseTasks dict

    /// Reconstructs the empirical repro from the original E8 finding: a
    /// double-clicked Retry (or any other back-to-back subscribe(to:) call
    /// for the same book) previously left `sseTasks[bookID]` nil'd out by the
    /// first (superseded) task's unconditional deferred cleanup, even though
    /// a second, still-live task was the real current subscription.
    func test_doubleSubscribe_doesNotDesyncSSETaskDict() async {
        let streams = HeldEventStreams()
        let vm = AudiobookViewModel(audio: AudioService(), processingEvents: streams.stream)
        let bookID = "book-e8-\(UUID().uuidString)"

        vm.subscribe(to: bookID)
        XCTAssertTrue(vm.hasActiveSSETask(for: bookID))

        // Immediate double-subscribe — cancels the first task, installs a second.
        vm.subscribe(to: bookID)

        // Let the superseded task observe cancellation and run its deferred
        // cleanup. No wall-clock sleep or loopback network request is needed.
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(
            vm.hasActiveSSETask(for: bookID),
            "E8: the first (superseded) task's deferred cleanup must not clear the dict slot the second, still-live task owns"
        )

        vm.cancelSubscription(for: bookID)
        XCTAssertFalse(vm.hasActiveSSETask(for: bookID))
    }

    // MARK: - T7.10/E11: stalled/reconnecting state

    func test_applyStalled_setsReconnectingState() {
        let vm = makeVM()
        vm.applyStalled(bookID: "book-stalled")
        XCTAssertEqual(vm.processingState["book-stalled"], .reconnecting)
        XCTAssertTrue(ProcessingStatus.reconnecting.isProcessing, "a stalled/reconnecting book is still processing server-side")
    }

    func test_applyStalled_isSupersededByNextRealEvent() {
        let vm = makeVM()
        let bookID = "book-recovering"
        vm.applyStalled(bookID: bookID)
        XCTAssertEqual(vm.processingState[bookID], .reconnecting)

        // Reconnect succeeds; a fresh snapshot arrives — must supersede the
        // stalled state with no explicit "recovered" transition needed.
        vm.applyStatus(bookID: bookID, status: "tts", pageDone: 3, pageTotal: 10, error: nil)
        XCTAssertEqual(vm.processingState[bookID], .generating(page: 3, total: 10))
    }

    // MARK: - T7.11/E12: cancel() surfaces a toast on failure

    func test_cancelBook_showsToastOnFailure() async {
        let vm = makeVM()
        let book = makeBook(id: "book-cancel-fail-\(UUID().uuidString)")
        XCTAssertNil(vm.toast)

        vm.cancel(book)
        // Fails for a book that doesn't exist server-side (404 from a live
        // backend, or a connection error with none running) either way.
        for _ in 0 ..< 40 {
            if vm.toast != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNotNil(vm.toast, "E12: a failed cancel request must surface a toast instead of silently no-op'ing")
        XCTAssertEqual(vm.toast?.kind, .error)
    }
}
