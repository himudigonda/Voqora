import AppKit
import Combine
import CryptoKit
import SwiftUI

/// SHA-256 hex of a string. Used to anonymize book ids before they leave the device
/// (see `docs/specs/accounts-analytics.md` §5.3).
private func sha256Hex(_ input: String) -> String {
    let digest = SHA256.hash(data: Data(input.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

@MainActor
final class AudiobookViewModel: ObservableObject {
    // Dependencies
    private let service: AudiobookService
    let audio: AudioService

    // Library
    @Published var books: [Audiobook] = []
    @Published var nowPlaying: Audiobook? = nil
    /// Held only briefly during upload-modal failure paths. All other error
    /// surfaces flow through `toast`. Kept so the upload modal can show a
    /// dedicated error state without competing with a global toast.
    @Published var loadingError: String? = nil
    @Published var hasLoadedOnce: Bool = false

    // Upload flow
    @Published var pendingPDF: URL? = nil
    @Published var pendingEstimate: AudiobookEstimateResponse? = nil
    @Published var uploadInProgress = false
    @Published var completionSummary: Audiobook? = nil

    /// A PDF drop queued while another upload was already pending.
    private struct QueuedUpload {
        let pdf: URL
        let voice: String
        let speed: Double
        let engine: String
    }

    /// Queue of PDFs dropped while another upload was already pending.
    /// They are processed one after the other.
    private var uploadQueue: [QueuedUpload] = []

    // Toast / banner for transient errors (B4).
    @Published var toast: Toast? = nil
    private var toastDismissTask: Task<Void, Never>?

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let kind: Kind
        enum Kind: Equatable { case error, info, success }
    }

    // Settings (Keychain-backed Gemini key)
    @Published var draftKey: String = ""
    @Published var keyVerified: Bool = false
    @Published var verifyingKey: Bool = false
    @AppStorage("defaultBookSpeed") var defaultBookSpeed: Double = 1.0
    @AppStorage("defaultBookVoice") var defaultBookVoice: String = "af_bella"
    @AppStorage("lastPlayedBookID") var lastPlayedBookID: String = ""

    /// True while the /start network call is in flight; prevents double-tap and
    /// drives a loading indicator in UploadEstimateModal.
    @Published var startingProcessing: Bool = false

    // Per-book live processing state, keyed by book_id.
    @Published var processingState: [String: ProcessingStatus] = [:]
    private var sseTasks: [String: Task<Void, Never>] = [:]
    /// Per-bookID generation token (the v1.1 design notes Sprint 7, T7.8/E8): bumped on
    /// every `subscribe(to:)` call. A subscription's deferred cleanup only
    /// clears its `sseTasks` slot if this still matches — see `subscribe(to:)`.
    private var sseGeneration: [String: UUID] = [:]

    /// Polling for library refresh.
    private var pollTask: Task<Void, Never>?

    // Transcript for the currently-playing book (for live highlighting).
    @Published var currentTranscript: AudiobookService.Transcript?
    private var transcriptTask: Task<Void, Never>?

    /// Set by sidebar / NowPlayingBar when the user wants to navigate into
    /// the player. The library view observes this and pushes onto its
    /// NavigationStack, then clears it. Avoids each entry-point needing a
    /// reference to the path binding.
    @Published var pendingDeepLink: String? = nil

    func openPlayer(for bookID: String) {
        pendingDeepLink = bookID
    }

    /// True while `AudiobookPlayerView` is the front-most visible view (set
    /// by its own onAppear/onDisappear — the NavigationStack push/pop is the
    /// actual source of truth for whether the player is on screen). Lets
    /// `NowPlayingBar` distinguish "a book is playing" from "that book's own
    /// player is already on screen" — the v1.1 design notes Sprint 6, T6.1 (Defect A: the
    /// bar previously rendered underneath the player nearly always, since
    /// opening the player itself calls `play()`, making `nowPlaying` non-nil
    /// for the entire time the player view is up).
    @Published var isPlayerViewActive: Bool = false

    /// Single source of truth for `NowPlayingBar`'s visibility gate —
    /// extracted so the condition is unit-testable, not just inline in
    /// VoqoraWindow's view body.
    var isNowPlayingBarVisible: Bool {
        nowPlaying != nil && !isPlayerViewActive
    }

    // Sleep timer
    @Published var sleepTimerEndsAt: Date? = nil
    @Published var sleepUntilEndOfBook: Bool = false
    private var sleepTimerTask: Task<Void, Never>?

    private var completionObserver: AnyCancellable?

    init(service: AudiobookService? = nil, audio: AudioService) {
        self.service = service ?? AudiobookService()
        self.audio = audio
        keyVerified = KeychainService.has(.geminiAPIKey)
        if let stored = KeychainService.get(.geminiAPIKey) {
            draftKey = stored
        }
        // Clear saved position when a book plays to its natural end.
        completionObserver = audio.$playbackCompleted
            .filter(\.self)
            .sink { [weak self] _ in
                guard let self, let book = nowPlaying else { return }
                UserDefaults.standard.removeObject(forKey: "bookPos_\(book.bookID)")
                MetricsService.shared.trackAudiobookPlay(
                    bookIDHash: sha256Hex(book.bookID),
                    secondsPlayed: self.audio.duration
                )
            }
    }

    var hasStoredKey: Bool {
        KeychainService.has(.geminiAPIKey)
    }

    // MARK: - Library

    func refresh() async {
        do {
            let fresh = try await service.list()
            books = fresh
            hasLoadedOnce = true
            // Keep processingState in sync with anything still in flight.
            for book in fresh {
                processingState[book.bookID] = book.displayStatus
                if book.displayStatus.isProcessing, sseTasks[book.bookID] == nil {
                    subscribe(to: book.bookID)
                }
            }
        } catch {
            showToast("Could not load library: \(error.localizedDescription)", kind: .error)
            hasLoadedOnce = true
        }
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // S1: skip the poll if any book has an active SSE subscription
                // — SSE is the source of truth and will keep state fresh.
                // We still poll occasionally to pick up library-level changes
                // (new books from another window, deletions etc.) so use a
                // longer interval when an SSE is live.
                let hasActiveSSE = !sseTasks.isEmpty
                if !hasActiveSSE {
                    await refresh()
                }
                let interval: UInt64 = hasActiveSSE ? 15_000_000_000 : 5_000_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Upload flow

    /// Task handle for the in-flight upload POST, so `cancelUpload()` can
    /// invalidate it (the v1.1 design notes Sprint 7, T7.6/E6): dismissing the modal while
    /// the request is still in flight must not let a subsequent success
    /// resurrect `pendingEstimate` for a book the user already dismissed.
    private var uploadTask: Task<Void, Never>?

    /// Drop hook used by the library + global drop. Snapshots the user's current
    /// engine/voice/speed so the book is generated with what they expect.
    func presentEstimate(for pdf: URL, voice: String, speed: Double, engine: String) {
        if pendingPDF != nil || uploadInProgress {
            // A modal is already up — queue this drop for later.
            uploadQueue.append(QueuedUpload(pdf: pdf, voice: voice, speed: speed, engine: engine))
            showToast("Queued '\(pdf.lastPathComponent)'", kind: .info)
            return
        }
        pendingPDF = pdf
        pendingEstimate = nil
        uploadTask = Task {
            uploadInProgress = true
            defer { uploadInProgress = false }
            do {
                let estimate = try await service.upload(pdf: pdf, voice: voice, speed: speed, engine: engine)
                // E6: cancelUpload() may have dismissed the modal while this
                // request was in flight — pendingEstimate was still nil at
                // that moment so its own cleanup couldn't delete this book.
                // Don't let a late success resurrect the modal; clean up the
                // now-orphaned server-side book instead.
                guard !Task.isCancelled else {
                    Task { try? await service.delete(estimate.bookID) }
                    return
                }
                pendingEstimate = estimate
                MetricsService.shared.trackAudiobookUpload(
                    pages: estimate.pageCount,
                    fileKind: pdf.pathExtension.lowercased()
                )
            } catch {
                guard !Task.isCancelled else { return }
                showToast(error.localizedDescription, kind: .error)
                pendingPDF = nil
            }
        }
    }

    func cancelUpload() {
        // E6: invalidate the in-flight upload (if any) so its completion
        // handler's staleness check fires instead of committing
        // pendingEstimate for a book this dismissal already abandoned.
        uploadTask?.cancel()
        uploadTask = nil
        if let est = pendingEstimate {
            // Throw away the staged book so it doesn't sit in the library forever.
            Task { try? await service.delete(est.bookID) }
        }
        pendingPDF = nil
        pendingEstimate = nil
        // Drain the queue if anything is waiting.
        flushUploadQueue()
    }

    /// Internal (not private) so tests can assert the queue was actually
    /// drained (the v1.1 design notes Sprint 7, T7.7/T7.9) without depending on the timing
    /// of whatever upload the dequeued item itself kicks off next.
    var queuedUploadCount: Int {
        uploadQueue.count
    }

    private func flushUploadQueue() {
        guard !uploadQueue.isEmpty else { return }
        let next = uploadQueue.removeFirst()
        presentEstimate(for: next.pdf, voice: next.voice, speed: next.speed, engine: next.engine)
    }

    func startProcessing(consent: Bool) {
        guard let est = pendingEstimate else { return }
        guard !startingProcessing else { return }
        guard let key = KeychainService.get(.geminiAPIKey) else {
            showToast("Set a Gemini API key in Preferences first.", kind: .error)
            return
        }
        let bookID = est.bookID
        startingProcessing = true
        Task {
            defer { startingProcessing = false }
            do {
                try await service.start(bookID, apiKey: key, consent: consent)
                // Clear pendingPDF/pendingEstimate to collapse the sheet binding → modal
                // dismisses automatically without calling cancelUpload().
                pendingPDF = nil
                pendingEstimate = nil
                await refresh()
                subscribe(to: bookID)
                flushUploadQueue()
            } catch {
                showToast(error.localizedDescription, kind: .error)
                // /start failed — the book was staged but never started; delete orphan.
                Task { try? await service.delete(bookID) }
                pendingPDF = nil
                pendingEstimate = nil
                // E7: the success path already does this — without it here too,
                // any file queued behind this failed one is silently lost forever.
                flushUploadQueue()
            }
        }
    }

    func showToast(_ message: String, kind: Toast.Kind = .info) {
        // S4: cancel any previously-scheduled dismiss so a stale 4 s timer
        // doesn't kill this fresh toast a fraction of a second later.
        toastDismissTask?.cancel()
        let new = Toast(message: message, kind: kind)
        toast = new
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled {
                return
            }
            if self?.toast?.id == new.id {
                self?.toast = nil
            }
        }
    }

    func dismissToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        toast = nil
    }

    // MARK: - Retry / Resume

    func retry(_ book: Audiobook) {
        guard let key = KeychainService.get(.geminiAPIKey) else {
            showToast("Set a Gemini API key in Preferences first.", kind: .error)
            return
        }
        Task {
            do {
                let count = try await service.retry(book.bookID, apiKey: key)
                showToast(count > 0 ? "Retrying \(count) page(s)..." : "Restarting book...", kind: .info)
                await refresh()
                subscribe(to: book.bookID)
            } catch {
                showToast(error.localizedDescription, kind: .error)
            }
        }
    }

    func resumeNeedsKey(_ book: Audiobook) {
        // Same code path as retry — the backend re-enqueues from the saved meta.
        retry(book)
    }

    /// Internal (not private) so `AudiobookViewModelTests` can drive the
    /// double-subscribe race directly (the v1.1 design notes Sprint 7, T7.8/E8) — same
    /// "no protocol seam for AudiobookService" limitation noted on
    /// `applyStatus`, so exercising this via real SSE traffic end-to-end
    /// isn't reliable in a unit test.
    func subscribe(to bookID: String) {
        sseTasks[bookID]?.cancel()
        let generation = UUID()
        sseGeneration[bookID] = generation
        sseTasks[bookID] = Task { [weak self] in
            defer {
                // E8: only clear this bookID's dict slots if we're still the
                // current generation — otherwise a newer subscribe(to:) call
                // (e.g. a double-clicked Retry) already replaced us, and
                // clearing here would desync the dict from that live task,
                // making refresh() think no subscription exists and
                // re-subscribe on every poll forever.
                if self?.sseGeneration[bookID] == generation {
                    self?.sseTasks[bookID] = nil
                    self?.sseGeneration[bookID] = nil
                }
            }
            guard let self else { return }
            for await event in service.subscribe(to: bookID) {
                let type = event["type"] as? String ?? ""
                if type == "snapshot" {
                    if let status = event["status"] as? String {
                        let pageDone = ((event["phase_progress"] as? [String: Any])?["page_done"] as? Int) ?? 0
                        let pageTotal = ((event["phase_progress"] as? [String: Any])?["page_total"] as? Int) ?? 0
                        applyStatus(bookID: bookID, status: status, pageDone: pageDone, pageTotal: pageTotal, error: event["error"] as? String)
                    }
                } else if type == "phase_started" || type == "page_done" {
                    let phase = event["phase"] as? String ?? ""
                    let page = event["page"] as? Int ?? 0
                    let total = event["total"] as? Int ?? 0
                    applyPhase(bookID: bookID, phase: phase, page: page, total: total)
                } else if type == "phase_finished" {
                    let phase = event["phase"] as? String ?? ""
                    if phase == "cleaning" {
                        let pages = (event["total"] as? Int) ?? (books.first(where: { $0.bookID == bookID })?.pageCount ?? 0)
                        MetricsService.shared.trackGeminiClean(pages: pages, charsOut: 0)
                    }
                } else if type == "stalled" {
                    applyStalled(bookID: bookID)
                } else if type == "done" {
                    // Refresh the library list AND fetch the canonical detail
                    // for this book so we present the completion modal even
                    // if list endpoint is racing the meta.json write (C7).
                    await refresh()
                    let book = await fetchDetailWithFallback(bookID: bookID)
                    if let book {
                        completionSummary = book
                    }
                    break
                } else if type == "failed" || type == "cancelled" {
                    await refresh()
                    break
                }
            }
        }
    }

    /// Internal (not private) — lets tests probe whether a subscription is
    /// still tracked for a book without exposing the `Task` handle itself
    /// (the v1.1 design notes Sprint 7, T7.8/E8).
    func hasActiveSSETask(for bookID: String) -> Bool {
        sseTasks[bookID] != nil
    }

    /// Try the in-memory `books` list first, then a direct GET, with up to 3
    /// retries spaced 200 ms apart. Used to defeat the SSE-done-vs-meta.json
    /// write race (C7).
    private func fetchDetailWithFallback(bookID: String) async -> Audiobook? {
        for attempt in 0 ..< 3 {
            if let local = books.first(where: { $0.bookID == bookID }), local.status == "done" {
                return local
            }
            if let remote = try? await service.get(bookID), remote.status == "done" {
                return remote
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            if attempt < 2 {
                await refresh()
            }
        }
        // Last-ditch: return whatever we have, even if status hasn't flipped to done.
        if let local = books.first(where: { $0.bookID == bookID }) {
            return local
        }
        return try? await service.get(bookID)
    }

    /// Internal (not private) so `AudiobookViewModelTests` can drive these
    /// directly via `@testable import` (the v1.1 design notes Sprint 4, T4.2). Exercising
    /// the real live-event path end-to-end isn't feasible in a unit test —
    /// `AudiobookService` is a `final class` making real `URLSession`/SSE
    /// calls with no protocol seam to substitute — so this mirrors the
    /// existing `isPlayerViewActive` precedent (Sprint 6) of keeping
    /// test-relevant state at `internal` visibility rather than building new
    /// mocking infrastructure just for this.
    func applyStatus(bookID: String, status: String, pageDone: Int, pageTotal: Int, error: String?) {
        let s: ProcessingStatus = switch status {
        case "extracting": .extracting(page: pageDone, total: pageTotal)
        case "cleaning": .cleaning(page: pageDone, total: pageTotal)
        case "sectioning": .sectioning
        case "tts": .generating(page: pageDone, total: pageTotal)
        // D5/E9: backend's `_phase_concat` only sets `status` — it never
        // resets meta.json's `phase_progress` — so pageDone/pageTotal here
        // already carry over tts's final 100% in practice. Mirror
        // `Audiobook.displayStatus`'s own defensive convention exactly
        // (always pageTotal/pageTotal, never pageDone) anyway, so this
        // SSE-snapshot path and the REST-poll path can never disagree.
        case "concatenating": .generating(page: pageTotal, total: pageTotal)
        case "done": .ready
        case "needs_key": .needsKey
        case "failed": .failed(reason: error ?? "Unknown error")
        case "cancelled": .cancelled
        default: .queued
        }
        processingState[bookID] = s
    }

    /// See `applyStatus`'s doc comment for why this is `internal`, not `private`.
    ///
    /// D5/E9 fix: every phase's `phase_started` SSE event carries no
    /// page/total at all (`audiobook_service.py`'s `_emit` call sites never
    /// pass them for `phase_started`) — for "extracting"/"cleaning"/"tts"
    /// that's a harmless, sub-second blip because each is immediately
    /// followed by real per-page `page_done` events that correct it.
    /// "sectioning" and "concatenating" are monolithic: neither phase ever
    /// emits a `page_done`, so a naive 0/0 would sit on screen, unrefined,
    /// for the whole phase — for "concatenating" specifically, that means
    /// visibly regressing the just-completed 100% "tts" progress back to
    /// "GENERATING 0/0" right before every book finishes (100%
    /// reproducible, the v1.1 design notes E9).
    func applyPhase(bookID: String, phase: String, page: Int, total: Int) {
        let status: ProcessingStatus
        switch phase {
        case "extracting": status = .extracting(page: page, total: total)
        case "cleaning": status = .cleaning(page: page, total: total)
        case "tts": status = .generating(page: page, total: total)
        case "sectioning": status = .sectioning
        case "concatenating":
            // No per-item progress exists for this phase. Carry forward the
            // last known total (tts's completed page count) instead of
            // trusting this event's blank 0/0, mirroring
            // `Audiobook.displayStatus`'s poll-driven convention so the SSE
            // and poll paths can never disagree. Falls back to this event's
            // own (likely 0) total only when there's no prior state at all
            // to preserve — e.g. a fresh subscribe that lands mid-concat.
            if case let .generating(_, priorTotal) = processingState[bookID], priorTotal > 0 {
                status = .generating(page: priorTotal, total: priorTotal)
            } else {
                status = .generating(page: total, total: total)
            }
        default: return
        }
        processingState[bookID] = status
    }

    /// See `applyStatus`'s doc comment for why this is `internal`, not
    /// `private`. Called when `AudiobookService.subscribe(to:)` yields its
    /// synthetic `"stalled"` event after N consecutive SSE reconnect failures
    /// (the v1.1 design notes Sprint 7, T7.10/E11). No explicit "recovered" transition is
    /// needed: the next real event (a fresh snapshot on reconnect, or the
    /// next phase/page event) overwrites `processingState[bookID]` wholesale,
    /// the same way every other status transition already does.
    func applyStalled(bookID: String) {
        processingState[bookID] = .reconnecting
    }

    // MARK: - Playback

    /// Set true while a play() is in flight; prevents double-click race (S3).
    @Published private(set) var isLoadingAudio: Bool = false

    /// Bumped by every `play()` call and by `stopPlayback()` (the v1.1 design notes Sprint
    /// 7, T7.3/E3). An in-flight `play()` Task captures its own generation
    /// and re-checks it after each `await`; if `stopPlayback()` (or a newer
    /// `play()`) bumped the counter in the meantime, the stale Task bails out
    /// before mutating any further state instead of silently resurrecting
    /// playback after an explicit stop.
    private var playGeneration = 0

    func play(_ book: Audiobook) {
        guard !isLoadingAudio else { return }

        if nowPlaying?.bookID == book.bookID {
            if audio.playbackCompleted {
                // Book finished — fall through to restart from beginning
            } else if !audio.isPlaying {
                // Paused mid-playback — just resume, don't reload
                audio.togglePause()
                return
            } else {
                // Already playing
                return
            }
        } else if nowPlaying != nil {
            // E1: switching directly to a different book while one is already
            // loaded. Route through stopPlayback()'s existing teardown (saves
            // the outgoing book's position, cancels any sleep timer armed for
            // it) instead of a bare audio.stop() that silently skips both.
            stopPlayback()
        }

        isLoadingAudio = true
        currentTranscript = nil
        playGeneration += 1
        let generation = playGeneration
        Task { [weak self] in
            guard let self else { return }
            defer { isLoadingAudio = false }
            do {
                audio.stop()
                let url = try await service.ensureLocalAudio(for: book.bookID)
                // E3: stopPlayback()/delete()/a newer play() may have run
                // while the above await was in flight — bail out before any
                // further mutation instead of resurrecting playback.
                guard generation == playGeneration else { return }
                try audio.loadAndPlayWAV(at: url)
                // E2: only commit nowPlaying/lastPlayedBookID once the audio
                // actually loaded successfully — previously both were set
                // before this call, so a throw here left nowPlaying pointing
                // at a book with no audio loaded.
                nowPlaying = book
                lastPlayedBookID = book.bookID
                audio.setPlaybackRate(Float(defaultBookSpeed))
                // Restore saved position (skip trivially short seeks < 2 s)
                let savedTime = UserDefaults.standard.double(forKey: "bookPos_\(book.bookID)")
                if savedTime > 2.0 {
                    audio.seekAudiobook(toSeconds: savedTime)
                }
                transcriptTask?.cancel()
                transcriptTask = Task { [weak self] in
                    guard let self else { return }
                    let result = try? await service.transcript(for: book.bookID)
                    guard !Task.isCancelled else { return }
                    currentTranscript = result
                }
            } catch {
                guard generation == playGeneration else { return }
                showToast("Could not load audio: \(error.localizedDescription)", kind: .error)
            }
        }
    }

    /// Returns the most recently played book that's still ready, if any.
    var continueListeningBook: Audiobook? {
        guard !lastPlayedBookID.isEmpty else { return nil }
        return books.first(where: { $0.bookID == lastPlayedBookID && $0.status == "done" })
    }

    func togglePlayback() {
        if audio.isPlaying, let book = nowPlaying, audio.currentTime > 1.0 {
            UserDefaults.standard.set(audio.currentTime, forKey: "bookPos_\(book.bookID)")
        }
        audio.togglePause()
    }

    func stopPlayback() {
        // E3: invalidate any in-flight play() so it can't later resurrect
        // playback after this explicit stop.
        playGeneration += 1
        let nearEnd = audio.duration > 0 && audio.currentTime >= audio.duration - 5.0
        if let book = nowPlaying, audio.currentTime > 1.0, !audio.playbackCompleted, !nearEnd {
            UserDefaults.standard.set(audio.currentTime, forKey: "bookPos_\(book.bookID)")
        }
        // Emit audiobook_play on manual stop too (natural completion is handled
        // in the playbackCompleted observer). Only counts non-trivial sessions.
        if let book = nowPlaying, audio.currentTime > 5.0, !audio.playbackCompleted {
            MetricsService.shared.trackAudiobookPlay(
                bookIDHash: sha256Hex(book.bookID),
                secondsPlayed: audio.currentTime
            )
        }
        transcriptTask?.cancel()
        transcriptTask = nil
        audio.stop()
        nowPlaying = nil
        currentTranscript = nil
        cancelSleepTimer()
    }

    func seek(percentage: Double) {
        guard audio.duration > 0 else { return }
        audio.seekAudiobook(toSeconds: percentage * audio.duration)
    }

    func seek(toSeconds seconds: Double) {
        audio.seekAudiobook(toSeconds: seconds)
    }

    func skip(by seconds: Double) {
        guard audio.duration > 0 else { return }
        let target = max(0, min(audio.duration, audio.currentTime + seconds))
        audio.seekAudiobook(toSeconds: target)
    }

    // MARK: - Section navigation

    func currentSection(in book: Audiobook) -> AudiobookSection? {
        let t = audio.currentTime
        return book.sections
            .sorted { $0.startTime < $1.startTime }
            .last(where: { $0.startTime <= t })
    }

    func jumpToNextSection(in book: Audiobook) {
        let sorted = book.sections.sorted { $0.startTime < $1.startTime }
        let t = audio.currentTime
        if let next = sorted.first(where: { $0.startTime > t + 0.5 }) {
            seek(toSeconds: next.startTime)
        }
    }

    func jumpToPreviousSection(in book: Audiobook) {
        let sorted = book.sections.sorted { $0.startTime < $1.startTime }
        let t = audio.currentTime
        // If we're more than 3s into the current section, go to its start; else to prior section.
        if let current = sorted.last(where: { $0.startTime <= t }), t - current.startTime > 3 {
            seek(toSeconds: current.startTime)
            return
        }
        let prior = sorted.last(where: { $0.startTime < t - 1 })
        if let prior {
            seek(toSeconds: prior.startTime)
        } else {
            seek(toSeconds: 0)
        }
    }

    // MARK: - Sleep timer

    enum SleepDuration: String, Identifiable, CaseIterable {
        case fiveMinutes = "5m"
        case fifteenMinutes = "15m"
        case thirtyMinutes = "30m"
        case sixtyMinutes = "1h"
        case endOfSection = "End of section"
        case endOfBook = "End of book"

        var id: String {
            rawValue
        }

        var seconds: TimeInterval? {
            switch self {
            case .fiveMinutes: 300
            case .fifteenMinutes: 900
            case .thirtyMinutes: 1800
            case .sixtyMinutes: 3600
            default: nil
            }
        }
    }

    func startSleepTimer(_ option: SleepDuration, currentBook: Audiobook?) {
        cancelSleepTimer()
        if let secs = option.seconds {
            sleepTimerEndsAt = Date().addingTimeInterval(secs)
            scheduleSleepTask(after: secs)
        } else if option == .endOfSection {
            guard let book = currentBook,
                  let section = currentSection(in: book) else { return }
            let nextStart = book.sections
                .sorted { $0.startTime < $1.startTime }
                .first(where: { $0.startTime > section.startTime })?
                .startTime ?? book.totalAudioSeconds
            let remaining = max(0, nextStart - audio.currentTime)
            sleepTimerEndsAt = Date().addingTimeInterval(remaining)
            scheduleSleepTask(after: remaining)
        } else if option == .endOfBook {
            sleepUntilEndOfBook = true
            // Audio naturally ends on its own; stop on completion handled via audio.playbackCompleted.
        }
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndsAt = nil
        sleepUntilEndOfBook = false
    }

    private func scheduleSleepTask(after seconds: TimeInterval) {
        sleepTimerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            audio.stop()
            sleepTimerEndsAt = nil
            sleepTimerTask = nil
        }
    }

    var sleepRemainingSeconds: TimeInterval? {
        guard let end = sleepTimerEndsAt else { return nil }
        return max(0, end.timeIntervalSinceNow)
    }

    // MARK: - Cancel processing

    func cancel(_ book: Audiobook) {
        Task {
            do {
                try await service.cancel(book.bookID)
                await refresh()
            } catch {
                // E12: matches every other mutating action's convention —
                // a failed request surfaces a toast instead of silently no-op'ing.
                showToast(error.localizedDescription, kind: .error)
            }
        }
    }

    // MARK: - Delete

    func delete(_ book: Audiobook) {
        Task {
            do {
                try await service.delete(book.bookID)
            } catch {
                showToast("Could not delete book", kind: .error)
                return
            }
            // P1: clear Continue Listening pointer if the deleted book was it.
            if lastPlayedBookID == book.bookID {
                UserDefaults.standard.removeObject(forKey: "lastPlayedBookID")
                lastPlayedBookID = ""
            }
            // P5: drop processing-state entry so it doesn't leak.
            processingState.removeValue(forKey: book.bookID)
            await refresh()
            if nowPlaying?.bookID == book.bookID {
                stopPlayback()
            }
        }
    }

    // MARK: - Key

    /// Re-derive `keyVerified` from the Keychain. Useful for views that need
    /// to react to a change made elsewhere (e.g., user pasted a key in
    /// Preferences while an upload modal is up). S6.
    func refreshKeyState() {
        keyVerified = KeychainService.has(.geminiAPIKey)
    }

    func verifyAndSaveKey() {
        let trimmed = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            verifyingKey = true
            defer { verifyingKey = false }
            let ok = await service.verifyKey(trimmed)
            if ok {
                KeychainService.set(trimmed, for: .geminiAPIKey)
                keyVerified = true
            } else {
                keyVerified = false
                showToast("Could not verify that key. Double-check and retry.", kind: .error)
            }
        }
    }

    func removeKey() {
        KeychainService.delete(.geminiAPIKey)
        draftKey = ""
        keyVerified = false
    }
}
