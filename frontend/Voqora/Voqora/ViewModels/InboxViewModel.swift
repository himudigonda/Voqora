import AppKit
import Combine
import Foundation

nonisolated enum InboxSpeechPhase: Equatable, Sendable {
    case active
    case stopped

    init(_ status: AppStatus) {
        switch status {
        case .thinking, .speaking, .paused: self = .active
        case .ready, .error: self = .stopped
        }
    }
}

nonisolated struct InboxPlaybackSample: Equatable, Sendable {
    let spokenText: String?
    let progress: Double
    let completed: Bool
    let isSpeechSession: Bool
    var phase: InboxSpeechPhase = .active
}

struct InboxNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        case info
        case success
        case error
    }

    enum Action: Equatable {
        case makeAudiobook(URL)

        var title: String {
            switch self {
            case .makeAudiobook: "Make Audiobook"
            }
        }
    }

    let id = UUID()
    let message: String
    let kind: Kind
    var action: Action?

    static func == (lhs: InboxNotice, rhs: InboxNotice) -> Bool {
        lhs.message == rhs.message && lhs.kind == rhs.kind && lhs.action == rhs.action
    }
}

struct InboxDependencies {
    var extract: @MainActor (URL) async throws -> ExtractedArticle
    var importAudiobook: @MainActor (URL) -> Void
    var speak: @MainActor (String) async -> Bool
    var openURL: @MainActor (URL) -> Void
    var copyText: @MainActor (String) -> Void
    var notify: @MainActor (String, String) -> Void
    var playback: AnyPublisher<InboxPlaybackSample, Never>
    var now: @MainActor () -> Date
}

extension InboxDependencies {
    static func live(dashboard: DashboardViewModel, library: AudiobookViewModel) -> InboxDependencies {
        let articles = ArticleService()
        let speech = Publishers.CombineLatest4(
            dashboard.$spokenText,
            dashboard.audio.$progress,
            dashboard.audio.$playbackCompleted,
            library.$nowPlaying.map { $0 == nil }
        )
        let playback = Publishers.CombineLatest(speech, dashboard.$status.map(InboxSpeechPhase.init))
            .map { speech, phase in
                InboxPlaybackSample(
                    spokenText: speech.0,
                    progress: speech.1,
                    completed: speech.2,
                    isSpeechSession: speech.3,
                    phase: phase
                )
            }
            .eraseToAnyPublisher()
        return InboxDependencies(
            extract: { try await articles.extract($0) },
            importAudiobook: { url in
                library.importWebPage(
                    url,
                    voice: library.importVoice(fallback: dashboard.selectedVoice),
                    speed: library.importSpeed(fallback: dashboard.speechSpeed)
                )
                dashboard.showLibrary()
            },
            speak: { text in
                let wasOnline = dashboard.isBackendOnline
                await dashboard.speak(text: text, voice: nil)
                return wasOnline
            },
            openURL: { _ = NSWorkspace.shared.open($0) },
            copyText: { SystemPasteboard().write($0, transient: false) },
            notify: { PermissionsService.shared.scheduleNotification(title: $0, body: $1) },
            playback: playback,
            now: { Date() }
        )
    }
}

@MainActor
final class InboxViewModel: ObservableObject {
    enum Message {
        static let invalidLink = "Paste a web link that starts with http or https."
        static let noDroppedLink = "Drop a web link or a .webloc file to save it."
        static let noPastedLink = "Copy a web link first, then paste it here."
        static let missingArticle = "Voqora could not open this article. Delete it and add the link again."
        static let genericFailure = "Voqora couldn't add that page. Try again."
        static let copied = "Copied the article text."
        static let savedNotificationTitle = "Saved to Voqora Inbox"
        static let failedNotificationTitle = "Couldn't save to Voqora Inbox"
    }

    struct PendingLink: Identifiable, Equatable {
        let id: String
        let url: URL
        let announce: Bool
    }

    private struct ListeningSession {
        let itemID: InboxItem.ID
        let text: String
        var hasStarted = false
        var isArmed = false
        var savedProgress: Double
    }

    static let progressSaveStep = 0.02
    nonisolated static let noticeDismissNanoseconds: UInt64 = 5_000_000_000

    let store: InboxStore
    @Published var filter: InboxFilter = .unread
    @Published var searchText = ""
    @Published var linkDraft = ""
    @Published private(set) var pendingLinks: [PendingLink] = []
    @Published private(set) var listeningItemID: InboxItem.ID?
    @Published var notice: InboxNotice?

    private let dependencies: InboxDependencies
    private let noticeDismissDelay: UInt64
    private var listening: ListeningSession?
    private var extractionTask: Task<Void, Never>?
    private var extractionGeneration = 0
    private var speakTask: Task<Void, Never>?
    private var linkImportTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(store: InboxStore, dependencies: InboxDependencies, noticeDismissDelay: UInt64? = nil) {
        self.store = store
        self.dependencies = dependencies
        self.noticeDismissDelay = noticeDismissDelay ?? Self.noticeDismissNanoseconds
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        dependencies.playback
            .sink { [weak self] sample in self?.handlePlayback(sample) }
            .store(in: &cancellables)
    }

    var visibleItems: [InboxItem] {
        InboxFilter.visible(store.items, filter: filter, query: searchText)
    }

    var isEmpty: Bool {
        store.items.isEmpty && pendingLinks.isEmpty
    }

    func count(for filter: InboxFilter) -> Int {
        store.items.filter(filter.includes).count
    }

    @discardableResult
    func submitDraft() -> Bool {
        guard addLink(from: linkDraft) else { return false }
        linkDraft = ""
        return true
    }

    @discardableResult
    func addLink(from text: String, announce: Bool = false) -> Bool {
        guard let url = InboxLinkParser.webURL(from: text) else {
            post(InboxNotice(message: Message.invalidLink, kind: .error))
            return false
        }
        add(url, announce: announce)
        return true
    }

    func pasteLink(_ url: URL?) {
        guard let url else {
            post(InboxNotice(message: Message.noPastedLink, kind: .error))
            return
        }
        add(url)
    }

    func add(_ url: URL, announce: Bool = false) {
        guard let link = InboxLinkParser.validated(url) else {
            post(InboxNotice(message: Message.invalidLink, kind: .error))
            return
        }
        if let existing = store.item(matching: link) {
            revealExisting(existing)
            return
        }
        let key = InboxLinkParser.matchKey(for: link)
        guard !pendingLinks.contains(where: { $0.id == key }) else { return }
        pendingLinks.append(PendingLink(id: key, url: link, announce: announce))
        drainQueue()
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        importLinks(from: providers, emptyMessage: Message.noDroppedLink)
    }

    func handlePaste(_ providers: [NSItemProvider]) {
        if !importLinks(from: providers, emptyMessage: Message.noPastedLink) {
            post(InboxNotice(message: Message.noPastedLink, kind: .error))
        }
    }

    private func importLinks(from providers: [NSItemProvider], emptyMessage: String) -> Bool {
        let accepted = providers.filter(InboxDropReader.accepts)
        guard !accepted.isEmpty else { return false }
        linkImportTask = Task {
            let links = await InboxDropReader.links(from: accepted)
            guard !links.isEmpty else {
                post(InboxNotice(message: emptyMessage, kind: .error))
                return
            }
            for link in links {
                add(link)
            }
        }
        return true
    }

    func listen(to item: InboxItem) {
        guard let body = store.body(for: item.id) else {
            post(InboxNotice(message: Message.missingArticle, kind: .error))
            return
        }
        let text = Self.listeningText(title: item.title, body: body.text)
        listening = ListeningSession(itemID: item.id, text: text, savedProgress: item.progress)
        listeningItemID = item.id
        VoqoraLog.info("InboxViewModel", "Listening to an Inbox article", ["words": "\(item.wordCount)"])
        let itemID = item.id
        speakTask = Task {
            let accepted = await dependencies.speak(text)
            if !accepted, listening?.itemID == itemID {
                endListening()
            }
        }
    }

    func makeAudiobook(from item: InboxItem) {
        dependencies.importAudiobook(item.url)
    }

    func openOriginal(_ item: InboxItem) {
        dependencies.openURL(item.url)
    }

    func copyText(of item: InboxItem) {
        guard let body = store.body(for: item.id) else {
            post(InboxNotice(message: Message.missingArticle, kind: .error))
            return
        }
        dependencies.copyText(Self.listeningText(title: item.title, body: body.text))
        post(InboxNotice(message: Message.copied, kind: .success))
    }

    func toggleArchived(_ item: InboxItem) {
        store.setArchived(!item.isArchived, for: item.id)
    }

    func delete(_ item: InboxItem) {
        if listening?.itemID == item.id {
            endListening()
        }
        store.delete(item.id)
    }

    func perform(_ action: InboxNotice.Action) {
        notice = nil
        switch action {
        case let .makeAudiobook(url): dependencies.importAudiobook(url)
        }
    }

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    func eraseAll() throws {
        extractionTask?.cancel()
        extractionTask = nil
        extractionGeneration &+= 1
        pendingLinks.removeAll()
        endListening()
        try store.eraseAll()
    }

    func waitUntilIdle() async {
        await speakTask?.value
        await linkImportTask?.value
        while let task = extractionTask {
            await task.value
        }
    }

    static func listeningText(title: String, body: String) -> String {
        let parts = [title, body].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.joined(separator: "\n\n")
    }

    static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty {
            return description
        }
        return Message.genericFailure
    }

    private func drainQueue() {
        guard extractionTask == nil else { return }
        extractionGeneration &+= 1
        let generation = extractionGeneration
        extractionTask = Task {
            while let next = pendingLinks.first, !Task.isCancelled {
                await extract(next)
                guard generation == extractionGeneration else { return }
                pendingLinks.removeAll { $0.id == next.id }
            }
            if generation == extractionGeneration {
                extractionTask = nil
            }
        }
    }

    private func extract(_ link: PendingLink) async {
        do {
            let article = try await dependencies.extract(link.url)
            guard !Task.isCancelled else { return }
            switch try store.add(article, requestedURL: link.url, at: dependencies.now()) {
            case let .added(item):
                VoqoraLog.info("InboxViewModel", "Saved an article to the Inbox", ["words": "\(item.wordCount)"])
                post(InboxNotice(message: "Saved “\(item.title)” to your Inbox.", kind: .success))
                if link.announce {
                    dependencies.notify(Message.savedNotificationTitle, item.title)
                }
            case let .existing(item):
                revealExisting(item)
            }
        } catch is CancellationError {
            return
        } catch {
            let reason = (error as? ArticleServiceError)?.reason.rawValue ?? "inbox_save_failed"
            VoqoraLog.warn("InboxViewModel", "An article could not be saved", ["failureCode": reason])
            let message = Self.message(for: error)
            let isPDF = (error as? ArticleServiceError)?.reason == .pdfDocument
            post(InboxNotice(message: message, kind: .error, action: isPDF ? .makeAudiobook(link.url) : nil))
            if link.announce {
                dependencies.notify(Message.failedNotificationTitle, message)
            }
        }
    }

    private func revealExisting(_ item: InboxItem) {
        if item.isArchived {
            store.setArchived(false, for: item.id)
        }
        if let current = store.item(withID: item.id), !filter.includes(current) {
            filter = .all
        }
        post(InboxNotice(message: "“\(item.title)” is already in your Inbox.", kind: .info))
    }

    private func handlePlayback(_ sample: InboxPlaybackSample) {
        guard var session = listening else { return }
        guard sample.isSpeechSession, sample.spokenText == session.text else {
            if session.hasStarted {
                endListening()
            }
            return
        }
        if sample.phase == .active {
            session.isArmed = true
        }
        let stopped = session.isArmed && sample.phase == .stopped
        if !session.hasStarted {
            guard !sample.completed, sample.progress == 0 else {
                listening = session
                if stopped {
                    endListening()
                }
                return
            }
            session.hasStarted = true
        }
        let fraction = sample.completed ? 1 : min(max(sample.progress, 0), 1)
        let reachedEnd = fraction >= 1 && session.savedProgress < 1
        if fraction >= session.savedProgress + Self.progressSaveStep || reachedEnd {
            session.savedProgress = fraction
            store.setProgress(fraction, for: session.itemID)
        }
        listening = session
        if sample.completed || stopped {
            endListening()
        }
    }

    private func endListening() {
        listening = nil
        listeningItemID = nil
    }

    private func post(_ newNotice: InboxNotice) {
        noticeTask?.cancel()
        notice = newNotice
        guard newNotice.kind != .error, newNotice.action == nil else { return }
        let delay = noticeDismissDelay
        let id = newNotice.id
        noticeTask = Task {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, notice?.id == id else { return }
            notice = nil
        }
    }
}
