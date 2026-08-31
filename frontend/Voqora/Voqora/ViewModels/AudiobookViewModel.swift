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
    /// Narrow seam around the only long-running step in audiobook playback.
    /// Keeping it here makes the stop/delete race deterministic to exercise
    /// without changing the production service contract.
    private let localAudioURL: @MainActor (String) async throws -> URL

    // Library
    @Published var books: [Audiobook] = []
    @Published var nowPlaying: Audiobook? = nil
    /// Held only briefly during upload-modal failure paths. All other error
    /// surfaces flow through `toast`. Kept so the upload modal can show a
    /// dedicated error state without competing with a global toast.
    @Published var loadingError: String? = nil
    @Published var hasLoadedOnce: Bool = false
    /// T-17: distinguishes "the last `refresh()` failed" from a genuinely
    /// empty library, so the library view can render a distinct state
    /// instead of falling back to the same empty-shelf UI. Set on
    /// `refresh()`'s catch path, cleared on the next successful refresh.
    @Published var loadFailed: Bool = false

    // Upload flow
    @Published var pendingDocument: URL? = nil
    @Published var pendingEstimate: AudiobookEstimateResponse? = nil
    @Published var uploadInProgress = false
    @Published var completionSummary: Audiobook? = nil

    /// One document dropped while another upload was already pending.
    private struct QueuedUpload {
        let document: URL
        let voice: String
        let speed: Double
        let engine: String
    }

    /// Queue of documents dropped while another upload was already pending.
    /// They are processed one after the other.
    private var uploadQueue: [QueuedUpload] = []

    // Toast / banner for transient errors (B4).
    @Published var toast: Toast? = nil
    private var toastDismissTask: Task<Void, Never>? = nil

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
    /// `private(set)` (not `private`) so unit tests can observe the effect of
    /// the D1/T-7 race fix without a live backend.
    private(set) var sseTasks: [String: Task<Void, Never>] = [:]
    /// D1/T-7: one UUID minted per `subscribe(to:)` attempt for a book. A
    /// subscription's deferred cleanup only clears `sseTasks`/`sseGeneration`
    /// if it still owns this slot — otherwise a delayed cleanup from an older,
    /// already-superseded subscription (URLSession cancellation isn't
    /// instant) would wipe out a newer one's live registration. Mirrors
    /// AudioService's `volumeRampToken` (HARD-020).
    private var sseGeneration: [String: UUID] = [:]
    /// D2.2: monotonic token for `refresh()` calls. A slower-resolving
    /// overlapping refresh (plain polling racing a user action, or two
    /// closely-spaced user actions) must not apply its response after a
    /// newer refresh already did. Mirrors `DashboardViewModel.speakGeneration`.
    private var refreshGeneration = 0
    /// D2.3: monotonic token bumped the moment a "done" SSE event is
    /// *received*, before the async detail fetch that follows. Gates
    /// `completionSummary` writes so the event received last wins, not
    /// whichever fetch happens to resolve last. Mirrors
    /// `DashboardViewModel.errorResetGeneration`.
    private(set) var completionGeneration = 0

    // Polling for library refresh.
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

    /// The player view owns this visibility signal. It is deliberately
    /// separate from `nowPlaying`: an audiobook can keep playing after the
    /// user leaves the full player, while the compact bar must never render
    /// underneath that full player.
    @Published var isPlayerViewActive = false

    /// Single source of truth for the compact audiobook bar.
    var isNowPlayingBarVisible: Bool {
        nowPlaying != nil && !isPlayerViewActive
    }

    // Sleep timer
    @Published var sleepTimerEndsAt: Date? = nil
    @Published var sleepUntilEndOfBook: Bool = false
    private var sleepTimerTask: Task<Void, Never>?

    private var completionObserver: AnyCancellable?

    /// Test seam mirroring `localAudioURL`: lets tests simulate SSE events
    /// through a controlled `AsyncStream` instead of opening a real
    /// connection (needed to exercise the T-7/T-8/T-9 race fixes
    /// deterministically).
    private let subscribeToEvents: @MainActor (String) -> AsyncStream<[String: Any]>
    /// Test seam mirroring `localAudioURL`: lets tests control `refresh()`'s
    /// library snapshot deterministically instead of hitting a live backend.
    private let listBooks: @MainActor () async throws -> [Audiobook]

    init(
        service: AudiobookService? = nil,
        audio: AudioService,
        localAudioURL: (@MainActor (String) async throws -> URL)? = nil,
        subscribeToEvents: (@MainActor (String) -> AsyncStream<[String: Any]>)? = nil,
        listBooks: (@MainActor () async throws -> [Audiobook])? = nil
    ) {
        let resolvedService = service ?? AudiobookService()
        self.service = resolvedService
        self.audio = audio
        self.localAudioURL = localAudioURL ?? { bookID in
            try await resolvedService.ensureLocalAudio(for: bookID)
        }
        self.subscribeToEvents = subscribeToEvents ?? { bookID in resolvedService.subscribe(to: bookID) }
        self.listBooks = listBooks ?? { try await resolvedService.list() }
        self.keyVerified = KeychainService.has(.geminiAPIKey)
        if let stored = KeychainService.get(.geminiAPIKey) {
            self.draftKey = stored
        }
        // Clear saved position when a book plays to its natural end.
        // T-10: reads `audio.completedSessionID` (the book identity AudioService
        // captured when *that* session started) instead of `self.nowPlaying`
        // (read fresh here, at sink-execution time). If the user starts a new
        // book in the exact instant an older one finishes, `nowPlaying` may
        // have already moved on by the time this sink runs — the completed
        // session's own captured identity can't drift out from under it.
        completionObserver = audio.$playbackCompleted
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self, let bookID = self.audio.completedSessionID else { return }
                UserDefaults.standard.removeObject(forKey: "bookPos_\(bookID)")
                MetricsService.shared.trackAudiobookPlay(
                    bookIDHash: sha256Hex(bookID),
                    secondsPlayed: self.audio.duration
                )
            }
    }

    var hasStoredKey: Bool { KeychainService.has(.geminiAPIKey) }

    // MARK: - Library

    func refresh() async {
        // D2.2: reserve this call's place before the await so a slower-
        // resolving overlapping refresh can detect it's been superseded.
        refreshGeneration &+= 1
        let generation = refreshGeneration
        do {
            let fresh = try await listBooks()
            guard generation == refreshGeneration else { return }
            books = fresh
            hasLoadedOnce = true
            loadFailed = false
            // Keep processingState in sync with anything still in flight.
            for book in fresh {
                // D2.1: SSE already owns this book's live state while it has
                // an active subscription — a GET snapshot here can be stale
                // relative to an SSE event that already applied. This makes
                // the code actually honor the "SSE is source of truth"
                // comment on the poll loop below, not just gate whether
                // refresh() is *called*, but what it *writes* once called
                // from elsewhere (retry/startProcessing/cancel/delete).
                if sseTasks[book.bookID] == nil {
                    processingState[book.bookID] = book.displayStatus
                }
                if book.displayStatus.isProcessing && sseTasks[book.bookID] == nil {
                    subscribe(to: book.bookID)
                }
            }
        } catch {
            guard generation == refreshGeneration else { return }
            showToast("Could not load library: \(error.localizedDescription)", kind: .error)
            hasLoadedOnce = true
            loadFailed = true
        }
    }

    /// `.onDisappear` (which stops this poll) fires on in-app tab
    /// navigation, but not when the whole app is backgrounded while this
    /// view stays mounted — so this loop also widens its interval directly
    /// when backgrounded, to a 60 s floor. Never shrinks the interval.
    static func libraryPollInterval(hasActiveSSE: Bool, isBackgrounded: Bool) -> UInt64 {
        let baseInterval: UInt64 = hasActiveSSE ? 15_000_000_000 : 5_000_000_000
        return isBackgrounded ? max(baseInterval, 60_000_000_000) : baseInterval
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
                let hasActiveSSE = !self.sseTasks.isEmpty
                if !hasActiveSSE {
                    await self.refresh()
                }
                let interval = Self.libraryPollInterval(
                    hasActiveSSE: hasActiveSSE,
                    isBackgrounded: AppActivityMonitor.shared.isBackgrounded
                )
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Upload flow

    /// Drop hook used by the library + global drop. Snapshots the user's current
    /// engine/voice/speed so the book is generated with what they expect.
    func presentEstimate(for document: URL, voice: String, speed: Double, engine: String) {
        if pendingDocument != nil || uploadInProgress {
            // A modal is already up — queue this drop for later.
            uploadQueue.append(QueuedUpload(document: document, voice: voice, speed: speed, engine: engine))
            showToast("Queued '\(document.lastPathComponent)'", kind: .info)
            return
        }
        pendingDocument = document
        pendingEstimate = nil
        loadingError = nil
        Task {
            uploadInProgress = true
            defer { uploadInProgress = false }
            do {
                let estimate = try await service.upload(document: document, voice: voice, speed: speed, engine: engine)
                pendingEstimate = estimate
                MetricsService.shared.trackAudiobookUpload(
                    pages: estimate.pageCount,
                    fileKind: document.pathExtension.lowercased()
                )
            } catch {
                // Keep the estimate sheet open with a readable recovery state
                // instead of silently closing it after a failed upload.
                loadingError = error.localizedDescription
                showToast("Could not read this document. Check the file and try again.", kind: .error)
            }
        }
    }

    func cancelUpload() {
        let stagedDocument = pendingDocument
        if let est = pendingEstimate {
            // Throw away the staged book so it doesn't sit in the library forever.
            Task { try? await service.delete(est.bookID) }
        }
        pendingDocument = nil
        pendingEstimate = nil
        loadingError = nil
        AudiobookImportStaging.discard(stagedDocument)
        // Drain the queue if anything is waiting.
        flushUploadQueue()
    }

    private func flushUploadQueue() {
        guard !uploadQueue.isEmpty else { return }
        let next = uploadQueue.removeFirst()
        presentEstimate(for: next.document, voice: next.voice, speed: next.speed, engine: next.engine)
    }

    func startProcessing(useGeminiCleanup: Bool) {
        guard let est = pendingEstimate else { return }
        guard !startingProcessing else { return }
        let key = KeychainService.get(.geminiAPIKey)
        guard !useGeminiCleanup || key != nil else {
            showToast("Set a Gemini API key in Preferences first.", kind: .error)
            return
        }
        let bookID = est.bookID
        let stagedDocument = pendingDocument
        startingProcessing = true
        Task {
            defer { startingProcessing = false }
            do {
                try await service.start(
                    bookID,
                    apiKey: key,
                    useGeminiCleanup: useGeminiCleanup
                )
                // Clear pendingDocument/pendingEstimate to collapse the sheet binding → modal
                // dismisses automatically without calling cancelUpload().
                pendingDocument = nil
                pendingEstimate = nil
                AudiobookImportStaging.discard(stagedDocument)
                await refresh()
                subscribe(to: bookID)
                flushUploadQueue()
            } catch {
                showToast(error.localizedDescription, kind: .error)
                // /start failed — the book was staged but never started; delete orphan.
                Task { try? await service.delete(bookID) }
                pendingDocument = nil
                pendingEstimate = nil
                AudiobookImportStaging.discard(stagedDocument)
            }
        }
    }

    /// T-18: an error toast's message is no longer truncated (see
    /// AudiobookToastView.lineLimit(for:)), so it needs longer on screen to
    /// actually be read than a short info/success confirmation does.
    static func dismissDelayNanoseconds(for kind: Toast.Kind) -> UInt64 {
        kind == .error ? 8_000_000_000 : 4_000_000_000
    }

    func showToast(_ message: String, kind: Toast.Kind = .info) {
        // S4: cancel any previously-scheduled dismiss so a stale timer
        // doesn't kill this fresh toast a fraction of a second later.
        toastDismissTask?.cancel()
        let new = Toast(message: message, kind: kind)
        toast = new
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.dismissDelayNanoseconds(for: kind))
            if Task.isCancelled { return }
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
        let key = KeychainService.get(.geminiAPIKey)
        guard !book.requiresGeminiCleanup || key != nil else {
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

    /// Internal (not private) so unit tests can drive it directly with the
    /// `subscribeToEvents` seam instead of a live backend.
    func subscribe(to bookID: String) {
        sseTasks[bookID]?.cancel()
        // D1/T-7: mint a fresh token for *this* attempt. The deferred cleanup
        // below only fires for the attempt that still owns this slot.
        let token = UUID()
        sseGeneration[bookID] = token
        sseTasks[bookID] = Task { [weak self] in
            defer {
                if self?.sseGeneration[bookID] == token {
                    self?.sseTasks[bookID] = nil
                    self?.sseGeneration[bookID] = nil
                }
            }
            guard let self else { return }
            for await event in subscribeToEvents(bookID) {
                // T-7/T-9: a subscription superseded by a newer one (or
                // dropped by delete()) must stop applying events immediately,
                // not just eventually clean up its dictionary slot.
                guard sseGeneration[bookID] == token else { break }
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
                } else if type == "done" {
                    // D2.3: reserve this event's place in completion ordering
                    // *now*, before the slow refresh()/fetch below — receipt
                    // order, not resolution order, decides the winner.
                    let generation = beginCompletionFetch()
                    // Refresh the library list AND fetch the canonical detail
                    // for this book so we present the completion modal even
                    // if list endpoint is racing the meta.json write (C7).
                    await refresh()
                    let book = await fetchDetailWithFallback(bookID: bookID)
                    if let book {
                        applyCompletion(book, generation: generation)
                    }
                    break
                } else if type == "failed" || type == "cancelled" {
                    await refresh()
                    break
                }
            }
        }
    }

    /// Try the in-memory `books` list first, then a direct GET, with up to 3
    /// retries spaced 200 ms apart. Used to defeat the SSE-done-vs-meta.json
    /// write race (C7).
    private func fetchDetailWithFallback(bookID: String) async -> Audiobook? {
        for attempt in 0..<3 {
            if let local = books.first(where: { $0.bookID == bookID }), local.status == "done" {
                return local
            }
            if let remote = try? await service.get(bookID), remote.status == "done" {
                return remote
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            if attempt < 2 { await refresh() }
        }
        // Last-ditch: return whatever we have, even if status hasn't flipped to done.
        if let local = books.first(where: { $0.bookID == bookID }) {
            return local
        }
        return try? await service.get(bookID)
    }

    /// D2.3: call when a "done" SSE event is *received*, before the async
    /// detail fetch that follows. Returns the generation to pass to
    /// `applyCompletion` once that fetch resolves — reserves this event's
    /// place in completion ordering ahead of time.
    func beginCompletionFetch() -> Int {
        completionGeneration &+= 1
        return completionGeneration
    }

    /// D2.3: apply a completion fetch's result only if no newer "done" event
    /// has been received since `generation` was captured — a slow-resolving
    /// fetch for an older event must not clobber a newer one that already
    /// applied. Internal (not private) so unit tests can drive it directly.
    func applyCompletion(_ book: Audiobook, generation: Int) {
        guard generation == completionGeneration else { return }
        completionSummary = book
        PermissionsService.shared.scheduleNotification(
            title: "Audiobook ready",
            body: "\"\(book.title)\" is ready to listen."
        )
    }

    /// Internal (not private) so unit tests can drive the SSE `snapshot`
    /// mapping directly without a live backend.
    func applyStatus(bookID: String, status: String, pageDone: Int, pageTotal: Int, error: String?) {
        let s: ProcessingStatus
        switch status {
        case "extracting": s = .extracting(page: pageDone, total: pageTotal)
        case "cleaning": s = .cleaning(page: pageDone, total: pageTotal)
        case "sectioning": s = .sectioning(page: pageDone, total: pageTotal)
        case "tts", "concatenating": s = .generating(page: pageDone, total: pageTotal)
        case "done": s = .ready
        case "needs_key": s = .needsKey
        case "failed": s = .failed(reason: error ?? "Unknown error")
        case "cancelled": s = .cancelled
        default: s = .queued
        }
        processingState[bookID] = s
    }

    /// Internal (not private) so unit tests can drive the SSE `phase_started`/
    /// `page_done` mapping directly without a live backend.
    func applyPhase(bookID: String, phase: String, page: Int, total: Int) {
        let status: ProcessingStatus
        switch phase {
        case "extracting": status = .extracting(page: page, total: total)
        case "cleaning": status = .cleaning(page: page, total: total)
        case "sectioning": status = .sectioning(page: page, total: total)
        case "tts", "concatenating": status = .generating(page: page, total: total)
        default: return
        }
        processingState[bookID] = status
    }

    // MARK: - Playback

    /// Set true while a play() is in flight; prevents double-click race (S3).
    @Published private(set) var isLoadingAudio: Bool = false
    /// Each play/stop action receives a generation. A delayed local-file fetch
    /// from an older action must never resurrect audio after the user stopped,
    /// deleted, or switched books.
    private(set) var playbackGeneration = 0
    private var pendingPlaybackBookID: String?

    /// True while a local audiobook file is being prepared but has not yet
    /// become `nowPlaying`. Global Stop uses this so it can cancel that gap too.
    var isPreparingPlayback: Bool { pendingPlaybackBookID != nil }

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
        }

        if nowPlaying != nil {
            // Switching books must use the normal teardown path so the prior
            // resume point and listening metrics are not silently discarded.
            stopPlayback()
        }

        isLoadingAudio = true
        currentTranscript = nil
        playbackGeneration &+= 1
        let generation = playbackGeneration
        pendingPlaybackBookID = book.bookID
        Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.playbackGeneration {
                    self.isLoadingAudio = false
                    self.pendingPlaybackBookID = nil
                }
            }
            do {
                self.audio.stop()
                let url = try await self.localAudioURL(book.bookID)
                // The user may have stopped, deleted, or selected another
                // book while the file request was in flight.
                guard generation == self.playbackGeneration else { return }
                try self.audio.loadAndPlayWAV(at: url, sessionID: book.bookID)
                // stop() (called just above) resets the live rate to 1.0 —
                // reapply this book's chosen speed now that it's actually playing.
                self.audio.setPlaybackRate(Float(self.defaultBookSpeed))
                // Only commit user-visible playback state after loading
                // succeeded. A corrupted local audio file must not leave a
                // misleading "now playing" book with nothing loaded.
                self.nowPlaying = book
                self.lastPlayedBookID = book.bookID
                // Restore saved position (skip trivially short seeks < 2 s)
                let savedTime = UserDefaults.standard.double(forKey: "bookPos_\(book.bookID)")
                if savedTime > 2.0 { self.audio.seekAudiobook(toSeconds: savedTime) }
                self.transcriptTask?.cancel()
                self.transcriptTask = Task { [weak self] in
                    guard let self else { return }
                    let result = try? await self.service.transcript(for: book.bookID)
                    guard !Task.isCancelled else { return }
                    self.currentTranscript = result
                }
            } catch {
                guard generation == self.playbackGeneration else { return }
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

    /// - Parameter fadeOverSeconds: when set, fades output out over this
    ///   duration instead of stopping abruptly (used when a higher-priority
    ///   source, e.g. the global selected-text speech feature, interrupts
    ///   playback — see DashboardViewModel.speak()). Every other side effect
    ///   (resume-position save, metrics, transcript-task cancel, sleep-timer
    ///   cancel) is identical regardless of how the audio itself stops —
    ///   previously the interruption path bypassed this method entirely and
    ///   skipped all of them, most importantly the sleep timer: an armed
    ///   timer kept running and later called `audio.stop()` on whatever
    ///   later became "the shared audio" (a new TTS clip or a subsequently
    ///   started audiobook), stopping it with no explanation.
    func stopPlayback(fadeOverSeconds: TimeInterval? = nil) {
        // Invalidate an in-flight local-file request before touching audio.
        // Without this, a delayed request can schedule a new buffer after
        // the user explicitly pressed Stop.
        playbackGeneration &+= 1
        pendingPlaybackBookID = nil
        isLoadingAudio = false
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
        if let fadeOverSeconds {
            audio.fadeOutAndStop(over: fadeOverSeconds)
        } else {
            audio.stop()
        }
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

        var id: String { rawValue }
        var seconds: TimeInterval? {
            switch self {
            case .fiveMinutes: return 300
            case .fifteenMinutes: return 900
            case .thirtyMinutes: return 1800
            case .sixtyMinutes: return 3600
            default: return nil
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
            self.audio.stop()
            self.sleepTimerEndsAt = nil
            self.sleepTimerTask = nil
        }
    }

    var sleepRemainingSeconds: TimeInterval? {
        guard let end = sleepTimerEndsAt else { return nil }
        return max(0, end.timeIntervalSinceNow)
    }

    // MARK: - Cancel processing

    func cancel(_ book: Audiobook) {
        Task {
            await service.cancel(book.bookID)
            await refresh()
        }
    }

    // MARK: - Delete

    func delete(_ book: Audiobook) {
        // A loading book has no `nowPlaying` value yet, so invalidate it here
        // as well. Otherwise its request could finish after deletion and start
        // audio for a book that no longer exists in the library.
        if nowPlaying?.bookID == book.bookID || pendingPlaybackBookID == book.bookID {
            stopPlayback()
        }
        // T-9: cancel and drop this book's SSE subscription synchronously,
        // independent of whether the network delete below succeeds. Removing
        // sseGeneration[bookID] also makes subscribe()'s per-token guard
        // reject any event already in flight for the (now-stale) task.
        sseTasks[book.bookID]?.cancel()
        sseTasks.removeValue(forKey: book.bookID)
        sseGeneration.removeValue(forKey: book.bookID)
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
