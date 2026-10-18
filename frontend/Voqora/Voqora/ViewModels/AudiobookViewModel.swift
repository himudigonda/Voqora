import AppKit
import Combine
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

private func sha256Hex(_ input: String) -> String {
    let digest = SHA256.hash(data: Data(input.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

@MainActor
final class AudiobookViewModel: ObservableObject {
    private let service: AudiobookService
    let audio: AudioService
    let providers: LLMProviderStore
    private let localAudioURL: @MainActor (String) async throws -> URL

    @Published var books: [Audiobook] = []
    @Published var nowPlaying: Audiobook? = nil
    @Published var loadingError: String? = nil
    @Published var hasLoadedOnce: Bool = false
    @Published var loadFailed: Bool = false

    @Published var pendingSource: AudiobookImportSource? = nil
    @Published var isImporterPresented = false
    @Published var isWebPageImportPresented = false
    @Published private(set) var webPageDraft = ""
    @Published var pendingEstimate: AudiobookEstimateResponse? = nil
    @Published var uploadInProgress = false
    @Published private(set) var deletingAllBooks = false
    @Published var completionSummary: Audiobook? = nil

    var pendingDocument: URL? {
        get { pendingSource?.documentURL }
        set { pendingSource = newValue.map(AudiobookImportSource.document) }
    }

    private struct QueuedUpload {
        let source: AudiobookImportSource
        let voice: String
        let speed: Double
        let engine: String
    }

    struct ProviderFix: Identifiable, Equatable {
        let book: Audiobook
        let provider: LLMProvider?

        var id: String {
            "\(book.bookID)-\(provider?.rawValue ?? "add")"
        }
    }

    enum RetryPrompt: Identifiable, Equatable {
        case switchProvider(book: Audiobook, startedWith: LLMProvider, active: LLMProvider, startedWithConnected: Bool)
        case needsProvider(book: Audiobook, connected: [LLMProvider])

        var id: String {
            switch self {
            case let .switchProvider(book, _, _, _), let .needsProvider(book, _): book.bookID
            }
        }
    }

    enum RetryDecision: Equatable {
        case proceed(LLMProvider?)
        case confirmSwitch(startedWith: LLMProvider, active: LLMProvider, startedWithConnected: Bool)
        case needsProvider
    }

    @Published var providerFix: ProviderFix?
    @Published var resumeOffer: ProviderFix?
    @Published var retryPrompt: RetryPrompt?
    private struct FixSnapshot {
        let connected: [LLMProvider]
        let credential: LLMCredential?
        let saveCount: Int
    }

    private struct FinishedFix {
        let fix: ProviderFix
        let before: FixSnapshot
    }

    private var finishedFix: FinishedFix?
    private var startedFix: FixSnapshot?

    private var uploadQueue: [QueuedUpload] = []
    private var pendingUpload: QueuedUpload?
    private var uploadGeneration = 0

    var queuedUploadCount: Int {
        uploadQueue.count
    }

    @Published var toast: Toast? = nil
    private var toastDismissTask: Task<Void, Never>?

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let kind: Kind
        enum Kind: Equatable { case error, info, success }
    }

    @AppStorage("defaultBookSpeed") var defaultBookSpeed: Double = 1.0
    @AppStorage("audiobookPlaybackRate") private var playbackRate: Double = 1.0
    @AppStorage("defaultBookVoice") var defaultBookVoice: String = "af_bella"
    @AppStorage("lastPlayedBookID") var lastPlayedBookID: String = ""

    @Published var startingProcessing: Bool = false

    @Published var processingState: [String: ProcessingStatus] = [:]
    private(set) var sseTasks: [String: Task<Void, Never>] = [:]
    private var sseGeneration: [String: UUID] = [:]
    private var refreshGeneration = 0
    private(set) var completionGeneration = 0

    private var pollTask: Task<Void, Never>?

    @Published private(set) var transcriptState: TranscriptState = .idle
    let follower: TranscriptFollower
    private var transcriptTask: Task<Void, Never>?

    enum TranscriptState: Equatable {
        case idle
        case loading
        case loaded
        case unavailable
    }

    @Published var libraryPath: [AudiobookRoute] = []
    @Published private(set) var chapters: [AudiobookSection] = []
    private(set) lazy var exports = AudiobookExportController(dependencies: .live(service: service, viewModel: self))

    func openPlayer(for bookID: String) {
        libraryPath = [.player(bookID)]
    }

    @Published var isPlayerViewActive = false

    var isNowPlayingBarVisible: Bool {
        nowPlaying != nil && !isPlayerViewActive
    }

    @Published var sleepTimerEndsAt: Date? = nil
    @Published var sleepUntilEndOfBook: Bool = false
    @Published var sleepAtEndOfSection: Bool = false
    private var sleepTimerTask: Task<Void, Never>?

    private var completionObserver: AnyCancellable?
    private var resumePointSaver: AnyCancellable?
    private var sectionSleepObserver: AnyCancellable?
    private var listeningObservers: Set<AnyCancellable> = []

    private let subscribeToEvents: @MainActor (String) -> AsyncStream<[String: Any]>
    private let listBooks: @MainActor () async throws -> [Audiobook]

    init(
        service: AudiobookService? = nil,
        audio: AudioService,
        providers: LLMProviderStore? = nil,
        localAudioURL: (@MainActor (String) async throws -> URL)? = nil,
        subscribeToEvents: (@MainActor (String) -> AsyncStream<[String: Any]>)? = nil,
        listBooks: (@MainActor () async throws -> [Audiobook])? = nil
    ) {
        let resolvedService = service ?? AudiobookService()
        self.service = resolvedService
        self.audio = audio
        self.providers = providers ?? LLMProviderStore()
        self.localAudioURL = localAudioURL ?? { bookID in
            try await resolvedService.ensureLocalAudio(for: bookID)
        }
        self.subscribeToEvents = subscribeToEvents ?? { bookID in resolvedService.subscribe(to: bookID) }
        self.listBooks = listBooks ?? { try await resolvedService.list() }
        follower = TranscriptFollower(audio: audio)
        completionObserver = audio.$playbackCompleted
            .filter(\.self)
            .sink { [weak self] _ in
                guard let self, let bookID = self.audio.completedSessionID else { return }
                UserDefaults.standard.removeObject(forKey: "bookPos_\(bookID)")
                if sleepUntilEndOfBook {
                    cancelSleepTimer()
                }
                MetricsService.shared.trackAudiobookPlay(
                    bookIDHash: sha256Hex(bookID),
                    secondsPlayed: self.audio.duration
                )
            }
        resumePointSaver = audio.$currentTime
            .throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                guard let self, audio.isPlaying else { return }
                saveResumePoint()
            }
        sectionSleepObserver = audio.$currentTime
            .sink { [weak self] time in
                guard let self, sleepAtEndOfSection, audio.isPlaying,
                      let book = nowPlaying, let end = sectionEnd(in: book), time >= end - 1
                else { return }
                pauseForSleep(fadeOverSeconds: 1)
            }
        audio.$currentTime
            .sink { [weak self] _ in self?.tickListening() }
            .store(in: &listeningObservers)
        audio.$isPlaying
            .removeDuplicates()
            .sink { [weak self] playing in self?.tickListening(isPlaying: playing) }
            .store(in: &listeningObservers)
    }

    private func tickListening(isPlaying: Bool? = nil) {
        UsageStatsStore.shared.listeningTick(bookID: nowPlaying?.bookID, isPlaying: isPlaying ?? audio.isPlaying)
    }

    var cleanupCredential: LLMCredential? {
        providers.activeCredential
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        do {
            let fresh = try await listBooks()
            guard generation == refreshGeneration else { return }
            books = fresh
            hasLoadedOnce = true
            loadFailed = false
            for book in fresh {
                if sseTasks[book.bookID] == nil {
                    processingState[book.bookID] = book.displayStatus
                }
                if book.displayStatus.isProcessing, sseTasks[book.bookID] == nil {
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

    static func libraryPollInterval(hasActiveSSE: Bool, isBackgrounded: Bool) -> UInt64 {
        let baseInterval: UInt64 = hasActiveSSE ? 15_000_000_000 : 5_000_000_000
        return isBackgrounded ? max(baseInterval, 60_000_000_000) : baseInterval
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let hasActiveSSE = !sseTasks.isEmpty
                await refresh()
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

    func presentEstimate(for document: URL, voice: String, speed: Double, engine: String) {
        presentEstimate(for: .document(document), voice: voice, speed: speed, engine: engine)
    }

    func presentEstimate(for source: AudiobookImportSource, voice: String, speed: Double, engine: String) {
        let upload = QueuedUpload(source: source, voice: voice, speed: speed, engine: engine)
        if pendingSource != nil || uploadInProgress {
            uploadQueue.append(upload)
            showToast("Queued \(source.displayName)", kind: .info)
            return
        }
        pendingSource = source
        requestEstimate(upload, replacing: nil)
    }

    func importVoice(fallback: String) -> String {
        defaultBookVoice.isEmpty ? fallback : defaultBookVoice
    }

    func importSpeed(fallback: Double) -> Double {
        defaultBookSpeed > 0 ? defaultBookSpeed : fallback
    }

    func presentWebPageImport() {
        guard pendingSource == nil else { return }
        isWebPageImportPresented = true
    }

    func dismissWebPageImport() {
        isWebPageImportPresented = false
    }

    func importWebPage(_ url: URL, voice: String, speed: Double) {
        webPageDraft = url.absoluteString
        isWebPageImportPresented = false
        presentEstimate(for: .webPage(url), voice: voice, speed: speed, engine: "kokoro")
    }

    func editWebPageLink() {
        guard pendingSource?.webPageURL != nil else { return }
        cancelUpload()
        if pendingSource == nil {
            isWebPageImportPresented = true
        }
    }

    func refreshEstimate() {
        guard let upload = pendingUpload, pendingSource != nil, !startingProcessing else { return }
        requestEstimate(upload, replacing: pendingEstimate)
    }

    static func isEstimateStale(_ estimate: AudiobookEstimateResponse, credential: LLMCredential?) -> Bool {
        guard let credential else { return estimate.llmProvider != nil }
        if estimate.llmProvider != credential.provider.rawValue {
            return true
        }
        guard let model = estimate.llmModel else { return false }
        return model != credential.resolvedModel
    }

    private func requestEstimate(_ upload: QueuedUpload, replacing previous: AudiobookEstimateResponse?) {
        pendingUpload = upload
        pendingEstimate = nil
        loadingError = nil
        uploadGeneration &+= 1
        let generation = uploadGeneration
        uploadInProgress = true
        let credential = cleanupCredential
        Task {
            defer {
                if generation == uploadGeneration {
                    uploadInProgress = false
                }
            }
            if let previous {
                try? await service.delete(previous.bookID)
            }
            guard generation == uploadGeneration else { return }
            do {
                let estimate = try await fetchEstimate(for: upload, cleanup: credential)
                guard generation == uploadGeneration else {
                    try? await service.delete(estimate.bookID)
                    return
                }
                pendingEstimate = estimate
                if previous == nil {
                    MetricsService.shared.trackAudiobookUpload(pages: estimate.pageCount, fileKind: Self.fileKind(of: upload.source))
                }
            } catch {
                guard generation == uploadGeneration else { return }
                switch upload.source {
                case .document:
                    loadingError = error.localizedDescription
                    showToast("Could not read this document. Check the file and try again.", kind: .error)
                case .webPage:
                    loadingError = WebPageImportMessage.message(for: error)
                    VoqoraLog.warn("AudiobookViewModel", "Web page import failed", ["failureCode": Self.webImportFailureCode(for: error)])
                }
            }
        }
    }

    private func fetchEstimate(for upload: QueuedUpload, cleanup: LLMCredential?) async throws -> AudiobookEstimateResponse {
        switch upload.source {
        case let .document(document):
            try await service.upload(document: document, voice: upload.voice, speed: upload.speed, engine: upload.engine, cleanup: cleanup)
        case let .webPage(url):
            try await service.importWebPage(url, voice: upload.voice, speed: upload.speed, engine: upload.engine, cleanup: cleanup)
        }
    }

    static func fileKind(of source: AudiobookImportSource) -> String {
        switch source {
        case let .document(url): url.pathExtension.lowercased()
        case .webPage: "url"
        }
    }

    static func webImportFailureCode(for error: Error) -> String {
        guard let failure = error as? AudiobookAPIFailure else { return "web_import_transport_failed" }
        return failure.code ?? "web_import_http_\(failure.statusCode)"
    }

    func importDocument(_ url: URL, defaultVoice: String, defaultSpeed: Double) {
        guard AudiobookImportStaging.supports(url) else {
            showToast("Voqora audiobooks support \(AudiobookImportStaging.supportedFormatsDescription) files.", kind: .info)
            return
        }
        do {
            let staged = try AudiobookImportStaging.stageDocument(from: url)
            presentEstimate(
                for: staged,
                voice: importVoice(fallback: defaultVoice),
                speed: importSpeed(fallback: defaultSpeed),
                engine: "kokoro"
            )
        } catch {
            showToast("Could not prepare that document: \(error.localizedDescription)", kind: .error)
        }
    }

    func importDroppedDocuments(_ providers: [NSItemProvider], defaultVoice: String, defaultSpeed: Double) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        Task {
            var unreadableCount = 0
            var unsupportedCount = 0
            for provider in fileProviders {
                guard let url = await AudiobookImportStaging.fileURL(from: provider) else {
                    unreadableCount += 1
                    continue
                }
                guard AudiobookImportStaging.supports(url) else {
                    unsupportedCount += 1
                    continue
                }
                importDocument(url, defaultVoice: defaultVoice, defaultSpeed: defaultSpeed)
            }
            if unsupportedCount > 0 {
                showToast("Voqora audiobooks support \(AudiobookImportStaging.supportedFormatsDescription) files.", kind: .info)
            } else if unreadableCount > 0 {
                showToast("Voqora could not read that dropped file.", kind: .error)
            }
        }
        return true
    }

    func cancelUpload() {
        let stagedDocument = pendingDocument
        uploadGeneration &+= 1
        uploadInProgress = false
        if let est = pendingEstimate {
            Task { try? await service.delete(est.bookID) }
        }
        pendingSource = nil
        pendingUpload = nil
        pendingEstimate = nil
        loadingError = nil
        AudiobookImportStaging.discard(stagedDocument)
        flushUploadQueue()
    }

    private func flushUploadQueue() {
        guard !uploadQueue.isEmpty else { return }
        let next = uploadQueue.removeFirst()
        presentEstimate(for: next.source, voice: next.voice, speed: next.speed, engine: next.engine)
    }

    func startProcessing(useCleanup: Bool) {
        guard let est = pendingEstimate else { return }
        guard !startingProcessing else { return }
        let cleanup = useCleanup ? cleanupCredential : nil
        guard !useCleanup || cleanup != nil else {
            showToast(Self.missingProviderMessage, kind: .error)
            return
        }
        let bookID = est.bookID
        let stagedDocument = pendingDocument
        startingProcessing = true
        Task {
            defer { startingProcessing = false }
            do {
                try await service.start(bookID, cleanup: cleanup)
                UsageStatsStore.shared.recordDocumentAdded(pages: est.pageCount)
                pendingSource = nil
                pendingUpload = nil
                pendingEstimate = nil
                AudiobookImportStaging.discard(stagedDocument)
                await refresh()
                subscribe(to: bookID)
                flushUploadQueue()
            } catch {
                showToast(error.localizedDescription, kind: .error)
                Task { try? await service.delete(bookID) }
                pendingSource = nil
                pendingUpload = nil
                pendingEstimate = nil
                AudiobookImportStaging.discard(stagedDocument)
                flushUploadQueue()
            }
        }
    }

    static func dismissDelayNanoseconds(for kind: Toast.Kind) -> UInt64 {
        kind == .error ? 8_000_000_000 : 4_000_000_000
    }

    func showToast(_ message: String, kind: Toast.Kind = .info) {
        toastDismissTask?.cancel()
        let new = Toast(message: message, kind: kind)
        toast = new
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.dismissDelayNanoseconds(for: kind))
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

    static let missingProviderMessage = "Add an AI provider in Preferences first."

    static func retryDecision(
        requiresCleanup: Bool,
        startedWith: LLMProvider?,
        active: LLMProvider?,
        connected: [LLMProvider]
    ) -> RetryDecision {
        guard requiresCleanup else { return .proceed(nil) }
        guard let active else { return .needsProvider }
        if let startedWith, startedWith != active {
            return .confirmSwitch(startedWith: startedWith, active: active, startedWithConnected: connected.contains(startedWith))
        }
        return .proceed(active)
    }

    static func cleaningBookCount(
        provider: LLMProvider,
        activeProvider: LLMProvider?,
        books: [Audiobook],
        states: [String: ProcessingStatus]
    ) -> Int {
        books.count { book in
            guard book.requiresLLMCleanup, (states[book.bookID] ?? book.displayStatus).isProcessing else { return false }
            return book.cleanupProvider.map { $0 == provider } ?? (activeProvider == provider)
        }
    }

    func cleaningBookCount(using provider: LLMProvider) -> Int {
        Self.cleaningBookCount(
            provider: provider,
            activeProvider: providers.activeProvider,
            books: books,
            states: processingState
        )
    }

    func retry(_ book: Audiobook, using provider: LLMProvider? = nil) {
        if let provider {
            performRetry(book, cleanup: book.requiresLLMCleanup ? providers.credential(for: provider) : nil)
            return
        }
        switch Self.retryDecision(
            requiresCleanup: book.requiresLLMCleanup,
            startedWith: book.cleanupProvider,
            active: providers.activeProvider,
            connected: providers.connectedProviders
        ) {
        case .proceed:
            performRetry(book, cleanup: book.requiresLLMCleanup ? cleanupCredential : nil)
        case let .confirmSwitch(startedWith, active, startedWithConnected):
            retryPrompt = .switchProvider(
                book: book,
                startedWith: startedWith,
                active: active,
                startedWithConnected: startedWithConnected
            )
        case .needsProvider:
            retryPrompt = .needsProvider(book: book, connected: providers.connectedProviders)
        }
    }

    private func performRetry(_ book: Audiobook, cleanup: LLMCredential?) {
        guard !book.requiresLLMCleanup || cleanup != nil else {
            showToast(Self.missingProviderMessage, kind: .error)
            return
        }
        if nowPlaying?.bookID == book.bookID || pendingPlaybackBookID == book.bookID {
            stopPlayback()
        }
        Task {
            do {
                let count = try await service.retry(book.bookID, cleanup: cleanup)
                showToast(count > 0 ? "Retrying \(count) page(s)..." : "Restarting book...", kind: .info)
                await refresh()
                subscribe(to: book.bookID)
            } catch {
                showToast(error.localizedDescription, kind: .error)
            }
        }
    }

    func finishWithoutAI(_ book: Audiobook) {
        if nowPlaying?.bookID == book.bookID || pendingPlaybackBookID == book.bookID {
            stopPlayback()
        }
        Task {
            do {
                _ = try await service.retry(book.bookID, cleanup: nil, finishWithoutCleanup: true)
                showToast("Finishing without AI cleanup...", kind: .info)
                await refresh()
                subscribe(to: book.bookID)
            } catch {
                showToast(error.localizedDescription, kind: .error)
            }
        }
    }

    func resumeNeedsKey(_ book: Audiobook) {
        retry(book)
    }

    func fixProvider(for book: Audiobook) {
        guard let provider = book.providerToFix else {
            retry(book)
            return
        }
        beginProviderFix(ProviderFix(book: book, provider: provider))
    }

    func addProviderToResume(_ book: Audiobook) {
        beginProviderFix(ProviderFix(book: book, provider: nil))
    }

    private func beginProviderFix(_ fix: ProviderFix) {
        startedFix = FixSnapshot(connected: providers.connectedProviders, credential: fix.provider.flatMap(providers.credential(for:)), saveCount: providers.saveCount)
        providerFix = fix
    }

    func endProviderFix() {
        guard let fix = providerFix, let started = startedFix else {
            providerFix = nil
            return
        }
        finishedFix = FinishedFix(fix: fix, before: started)
        providerFix = nil
        startedFix = nil
    }

    func offerResumeAfterFix() {
        guard let finished = finishedFix else { return }
        finishedFix = nil
        let changed: Bool
        if let provider = finished.fix.provider {
            let now = providers.credential(for: provider)
            changed = now != nil && providers.saveCount != finished.before.saveCount
        } else {
            changed = providers.activeProvider != nil && providers.connectedProviders != finished.before.connected
        }
        if changed {
            resumeOffer = finished.fix
        }
    }

    func resumeAfterFix(_ fix: ProviderFix) {
        resumeOffer = nil
        retry(fix.book, using: fix.provider)
    }

    func subscribe(to bookID: String) {
        sseTasks[bookID]?.cancel()
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
                } else if type == "stalled" {
                    applyStalled(bookID: bookID)
                } else if type == "done" {
                    let generation = beginCompletionFetch()
                    await refresh()
                    let book = await fetchDetailWithFallback(bookID: bookID)
                    if let book {
                        applyCompletion(book, generation: generation)
                    }
                    break
                } else if type == "needs_cost_approval" {
                    processingState[bookID] = .needsCostApproval(requiredCap: event["required_cap_usd"] as? Double)
                    await refresh()
                    break
                } else if type == "failed" || type == "cancelled" {
                    if type == "failed" {
                        applyStatus(bookID: bookID, status: type, pageDone: 0, pageTotal: 0, error: event["error"] as? String)
                    }
                    await refresh()
                    break
                }
            }
        }
    }

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
        if let local = books.first(where: { $0.bookID == bookID }) {
            return local
        }
        return try? await service.get(bookID)
    }

    func beginCompletionFetch() -> Int {
        completionGeneration &+= 1
        return completionGeneration
    }

    func applyCompletion(_ book: Audiobook, generation: Int) {
        guard generation == completionGeneration else { return }
        completionSummary = book
        PermissionsService.shared.scheduleNotification(
            title: "Audiobook Ready",
            body: book.displayTitle
        )
    }

    func applyStatus(bookID: String, status: String, pageDone: Int, pageTotal: Int, error: String?) {
        let s: ProcessingStatus = switch status {
        case "extracting": .extracting(page: pageDone, total: pageTotal)
        case "cleaning": .cleaning(page: pageDone, total: pageTotal)
        case "sectioning": .sectioning(page: pageDone, total: pageTotal)
        case "tts": .generating(page: pageDone, total: pageTotal)
        case "concatenating": .finishing
        case "ready": .notStarted
        case "done": .ready
        case "needs_key": .needsKey
        case "needs_cost_approval": .needsCostApproval(requiredCap: nil)
        case "failed": .failed(reason: error ?? ProcessingStatus.unknownFailureReason)
        case "cancelled": .cancelled
        default: .queued
        }
        processingState[bookID] = s
    }

    func applyStalled(bookID: String) {
        processingState[bookID] = .reconnecting
    }

    func applyPhase(bookID: String, phase: String, page: Int, total: Int) {
        let status: ProcessingStatus
        switch phase {
        case "extracting": status = .extracting(page: page, total: total)
        case "cleaning": status = .cleaning(page: page, total: total)
        case "sectioning": status = .sectioning(page: page, total: total)
        case "tts": status = .generating(page: page, total: total)
        case "concatenating": status = .finishing
        default: return
        }
        processingState[bookID] = status
    }

    @Published private(set) var isLoadingAudio: Bool = false
    private(set) var playbackGeneration = 0
    private var pendingPlaybackBookID: String?

    var isPreparingPlayback: Bool {
        pendingPlaybackBookID != nil
    }

    func play(_ book: Audiobook) {
        guard !isLoadingAudio else { return }

        if nowPlaying?.bookID == book.bookID {
            if audio.playbackCompleted {
            } else if !audio.isPlaying {
                audio.togglePause()
                return
            } else {
                return
            }
        }

        if nowPlaying != nil {
            stopPlayback()
        }

        isLoadingAudio = true
        clearTranscript()
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
                audio.stop()
                let url = try await localAudioURL(book.bookID)
                guard generation == playbackGeneration else { return }
                let savedTime = UserDefaults.standard.double(forKey: "bookPos_\(book.bookID)")
                try audio.loadAndPlayWAV(
                    at: url,
                    sessionID: book.bookID,
                    startingAt: savedTime > 2.0 ? savedTime : 0
                )
                audio.setPlaybackRate(Float(playbackRate))
                nowPlaying = book
                chapters = Self.chapters(for: book, document: .empty)
                lastPlayedBookID = book.bookID
                loadTranscript(for: book.bookID)
            } catch {
                guard generation == playbackGeneration else { return }
                showToast("Could not load audio: \(error.localizedDescription)", kind: .error)
            }
        }
    }

    func validatedAudioURL(for book: Audiobook) async throws -> URL {
        guard book.status == "done" else {
            throw AudiobookServiceError.audioNotReady
        }
        return try await localAudioURL(book.bookID)
    }

    func listenedFraction(for book: Audiobook) -> Double {
        guard book.totalAudioSeconds > 0 else { return 0 }
        let seconds = nowPlaying?.bookID == book.bookID
            ? audio.currentTime
            : UserDefaults.standard.double(forKey: "bookPos_\(book.bookID)")
        return min(1, max(0, seconds / book.totalAudioSeconds))
    }

    var continueListeningBook: Audiobook? {
        let ready = books.filter { $0.status == "done" }
        if let last = ready.first(where: { $0.bookID == lastPlayedBookID }) {
            return last
        }
        return ready.first { UserDefaults.standard.double(forKey: "bookPos_\($0.bookID)") > 0 }
    }

    func togglePlayback() {
        if audio.isPlaying {
            saveResumePoint()
            audio.pause()
        } else {
            audio.resume()
        }
    }

    func loadTranscript(for bookID: String) {
        transcriptTask?.cancel()
        transcriptState = .loading
        transcriptTask = Task { [weak self, service] in
            let transcript = try? await service.transcript(for: bookID, includingWords: true)
            let document = await Task.detached(priority: .userInitiated) {
                transcript.map(TranscriptDocument.init(transcript:))
            }.value
            guard let self, !Task.isCancelled, nowPlaying?.bookID == bookID else { return }
            if let book = nowPlaying {
                chapters = Self.chapters(for: book, document: document ?? .empty)
            }
            if let document, !document.isEmpty {
                follower.load(document)
                transcriptState = .loaded
            } else {
                follower.clear()
                transcriptState = .unavailable
            }
        }
    }

    private func clearTranscript() {
        transcriptTask?.cancel()
        transcriptTask = nil
        transcriptState = .idle
        chapters = []
        follower.clear()
    }

    private func saveResumePoint() {
        guard let book = nowPlaying else { return }
        let key = "bookPos_\(book.bookID)"
        let nearEnd = audio.duration > 0 && audio.currentTime >= audio.duration - 5.0
        if audio.playbackCompleted || nearEnd {
            UserDefaults.standard.removeObject(forKey: key)
        } else if audio.currentTime > 1.0 {
            UserDefaults.standard.set(audio.currentTime, forKey: key)
        }
    }

    func stopPlayback(fadeOverSeconds: TimeInterval? = nil) {
        playbackGeneration &+= 1
        pendingPlaybackBookID = nil
        isLoadingAudio = false
        saveResumePoint()
        if let book = nowPlaying, audio.currentTime > 5.0, !audio.playbackCompleted {
            MetricsService.shared.trackAudiobookPlay(
                bookIDHash: sha256Hex(book.bookID),
                secondsPlayed: audio.currentTime
            )
        }
        clearTranscript()
        if let fadeOverSeconds {
            audio.fadeOutAndStop(over: fadeOverSeconds)
        } else {
            audio.stop()
        }
        nowPlaying = nil
        cancelSleepTimer()
    }

    func seek(toSeconds seconds: Double) {
        audio.seek(toSeconds: seconds)
        saveResumePoint()
    }

    func skip(by seconds: Double) {
        audio.skip(by: seconds)
        saveResumePoint()
    }

    func play(fromLine line: TranscriptLine) {
        audio.seek(toSeconds: line.start)
        if !audio.isPlaying {
            audio.resume()
        }
        saveResumePoint()
    }

    func chapters(for book: Audiobook) -> [AudiobookSection] {
        nowPlaying?.bookID == book.bookID && !chapters.isEmpty ? chapters : book.sortedSections
    }

    func currentSection(in book: Audiobook) -> AudiobookSection? {
        chapters(for: book).section(at: audio.currentTime)
    }

    static func chapters(for book: Audiobook, document: TranscriptDocument) -> [AudiobookSection] {
        let sections = book.sortedSections
        let titled = sections.filter { AudiobookImportStaging.displayName(from: $0.title).caseInsensitiveCompare(book.displayTitle) != .orderedSame }
        if titled.count >= 2 {
            return sections
        }
        var headings: [AudiobookSection] = []
        for line in document.lines where line.isHeading && line.isNarrated && TranscriptText.isChapterTitle(line.text) {
            guard headings.last?.title.caseInsensitiveCompare(line.text) != .orderedSame else { continue }
            headings.append(AudiobookSection(title: line.text, startPage: line.page, endPage: line.page, startTime: line.start))
        }
        guard headings.count >= 2 else { return sections }
        if let first = headings.first, first.startTime > 1 {
            let opening = AudiobookSection(title: book.displayTitle, startPage: 1, endPage: first.startPage, startTime: 0)
            if first.title.caseInsensitiveCompare(book.displayTitle) == .orderedSame {
                headings[0] = opening
            } else {
                headings.insert(opening, at: 0)
            }
        }
        return headings
    }

    func setSpeed(_ speed: Double) {
        let clamped = min(2.0, max(0.75, (speed * 100).rounded() / 100))
        playbackRate = clamped
        audio.setPlaybackRate(Float(clamped))
    }

    func jumpToNextSection(in book: Audiobook) {
        let starts = chapters(for: book).map(\.startTime)
        if let next = PlaybackTrackNavigation.nextStart(in: starts, after: audio.currentTime) {
            seek(toSeconds: next)
        }
    }

    func jumpToPreviousSection(in book: Audiobook) {
        let starts = chapters(for: book).map(\.startTime)
        seek(toSeconds: PlaybackTrackNavigation.previousStart(in: starts, before: audio.currentTime))
    }

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

        var menuTitle: String {
            switch self {
            case .fiveMinutes: "5 Minutes"
            case .fifteenMinutes: "15 Minutes"
            case .thirtyMinutes: "30 Minutes"
            case .sixtyMinutes: "1 Hour"
            case .endOfSection: "End of Section"
            case .endOfBook: "End of Book"
            }
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
            guard let book = currentBook, sectionEnd(in: book) != nil else { return }
            sleepAtEndOfSection = true
        } else if option == .endOfBook {
            sleepUntilEndOfBook = true
        }
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndsAt = nil
        sleepUntilEndOfBook = false
        sleepAtEndOfSection = false
    }

    func sectionEnd(in book: Audiobook) -> TimeInterval? {
        guard let section = currentSection(in: book) else { return nil }
        return chapters(for: book).first(where: { $0.startTime > section.startTime })?.startTime ?? book.totalAudioSeconds
    }

    private func scheduleSleepTask(after seconds: TimeInterval) {
        sleepTimerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            sleepTimerTask = nil
            pauseForSleep(fadeOverSeconds: 1.5)
        }
    }

    private func pauseForSleep(fadeOverSeconds: TimeInterval) {
        cancelSleepTimer()
        saveResumePoint()
        audio.fadeOutAndPause(over: fadeOverSeconds)
    }

    func cancel(_ book: Audiobook) {
        Task {
            do {
                try await service.cancel(book.bookID)
            } catch {
                showToast(error.localizedDescription, kind: .error)
            }
            await refresh()
        }
    }

    func delete(_ book: Audiobook) {
        if nowPlaying?.bookID == book.bookID || pendingPlaybackBookID == book.bookID {
            stopPlayback()
        }
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
            if lastPlayedBookID == book.bookID {
                UserDefaults.standard.removeObject(forKey: "lastPlayedBookID")
                lastPlayedBookID = ""
            }
            processingState.removeValue(forKey: book.bookID)
            await refresh()
        }
    }

    func resolveCostApproval(_ book: Audiobook, approveStandard: Bool) {
        let requiredCap = book.budget?.costApproval?.requiredCapUsd
        let cleanup = approveStandard ? providers.credential(for: .google) : nil
        guard !approveStandard || cleanup != nil else {
            showToast("Connect Google in Preferences before approving Standard-tier work.", kind: .error)
            return
        }
        Task {
            do {
                try await service.resolveCostApproval(
                    book.bookID,
                    approve: approveStandard,
                    newCapUSD: approveStandard ? requiredCap : nil,
                    cleanup: cleanup
                )
                showToast(
                    approveStandard ? "Approved Standard-tier cleanup." : "Finishing remaining pages locally.",
                    kind: .info
                )
                await refresh()
                subscribe(to: book.bookID)
            } catch {
                showToast(error.localizedDescription, kind: .error)
            }
        }
    }

    func deleteAllBooks() {
        Task { _ = await deleteAllBooksForErasure(showSuccess: true) }
    }

    @discardableResult
    func deleteAllBooksForErasure(showSuccess: Bool = false) async -> Bool {
        guard !deletingAllBooks else { return false }
        deletingAllBooks = true
        defer { deletingAllBooks = false }
        stopPlayback()
        sseTasks.values.forEach { $0.cancel() }
        sseTasks.removeAll()
        sseGeneration.removeAll()
        processingState.removeAll()
        do {
            try await service.deleteAll()
            books = []
            completionSummary = nil
            libraryPath = []
            lastPlayedBookID = ""
            if showSuccess {
                showToast("Deleted all local audiobooks and their source files.", kind: .success)
            }
            return true
        } catch {
            showToast("Could not delete every audiobook. Try again before removing Voqora data.", kind: .error)
            await refresh()
            return false
        }
    }
}
