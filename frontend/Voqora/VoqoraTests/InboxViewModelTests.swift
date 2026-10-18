import Combine
import Foundation
@testable import Voqora
import XCTest

@MainActor
final class InboxViewModelTests: XCTestCase {
    private var folder: URL!
    private var extractResults: [String: Result<ExtractedArticle, Error>] = [:]
    private var extracted: [URL] = []
    private var estimate: Result<AudiobookEstimateResponse, Error> = .failure(ArticleServiceError(.rejected))
    private var startError: Error?
    private var createdURLs: [URL] = []
    private var narrations: [AudiobookNarration] = []
    private var started: [String] = []
    private var discarded: [String] = []
    private var spoken: [String] = []
    private var copied: [String] = []
    private var opened: [URL] = []
    private var openedBooks: [String] = []
    private var notifications: [String] = []
    private var libraryRefreshes = 0
    private var playback: PassthroughSubject<InboxPlaybackSample, Never>!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraInboxViewModelTests-\(UUID().uuidString)", isDirectory: true)
        playback = PassthroughSubject()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func makeViewModel() -> InboxViewModel {
        let dependencies = InboxDependencies(
            extract: { [unowned self] url in
                extracted.append(url)
                guard let result = extractResults[url.absoluteString] else {
                    throw ArticleServiceError(.unreachable)
                }
                return try result.get()
            },
            createAudiobook: { [unowned self] url, narration in
                createdURLs.append(url)
                narrations.append(narration)
                return try estimate.get()
            },
            startAudiobook: { [unowned self] bookID in
                started.append(bookID)
                if let startError {
                    throw startError
                }
            },
            discardAudiobook: { [unowned self] bookID in discarded.append(bookID) },
            narration: { AudiobookNarration(voice: "af_bella", speed: 1.25) },
            speak: { [unowned self] text in spoken.append(text) },
            refreshLibrary: { [unowned self] in libraryRefreshes += 1 },
            openAudiobook: { [unowned self] bookID in openedBooks.append(bookID) },
            showLibrary: {},
            openURL: { [unowned self] url in opened.append(url) },
            copyText: { [unowned self] text in copied.append(text) },
            notify: { [unowned self] title, _ in notifications.append(title) },
            playback: playback.eraseToAnyPublisher(),
            now: { Date(timeIntervalSince1970: 500) }
        )
        return InboxViewModel(store: InboxStore(directory: folder), dependencies: dependencies, noticeDismissDelay: 60_000_000_000)
    }

    private func stub(_ link: String, title: String = "Story", text: String = "Body text.") {
        extractResults[link] = .success(InboxFixtures.article(url: link, title: title, text: text))
    }

    private func estimateResponse(bookID: String, duplicateOf: String?) throws -> AudiobookEstimateResponse {
        try JSONDecoder().decode(
            AudiobookEstimateResponse.self,
            from: Data(InboxFixtureJSON.estimate(bookID: bookID, duplicateOf: duplicateOf).utf8)
        )
    }

    func test_submittingADraftExtractsAndSavesTheArticle() async {
        stub("https://example.com/story", title: "Big Story")
        let inbox = makeViewModel()
        inbox.linkDraft = "  https://example.com/story "

        XCTAssertTrue(inbox.submitDraft())
        XCTAssertEqual(inbox.linkDraft, "")
        XCTAssertEqual(inbox.pendingLinks.map(\.url.absoluteString), ["https://example.com/story"])
        await inbox.waitUntilIdle()

        XCTAssertTrue(inbox.pendingLinks.isEmpty)
        XCTAssertEqual(inbox.store.items.map(\.title), ["Big Story"])
        XCTAssertEqual(inbox.store.items.first?.addedAt, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(inbox.notice?.kind, .success)
    }

    func test_invalidDraftShowsAnErrorAndKeepsTheText() {
        let inbox = makeViewModel()
        inbox.linkDraft = "not a link"

        XCTAssertFalse(inbox.submitDraft())

        XCTAssertEqual(inbox.linkDraft, "not a link")
        XCTAssertEqual(inbox.notice, InboxNotice(message: InboxViewModel.Message.invalidLink, kind: .error))
        XCTAssertTrue(extracted.isEmpty)
    }

    func test_duplicateLinksAreNotFetchedTwice() async throws {
        stub("https://example.com/story")
        let inbox = makeViewModel()
        let link = try XCTUnwrap(URL(string: "https://example.com/story"))

        inbox.add(link)
        inbox.add(link)
        await inbox.waitUntilIdle()
        try inbox.add(XCTUnwrap(URL(string: "http://example.com/story/")))

        XCTAssertEqual(extracted.count, 1)
        XCTAssertEqual(inbox.store.items.count, 1)
        XCTAssertEqual(inbox.notice?.kind, .info)
    }

    func test_addingAnArchivedLinkAgainMovesItBackToTheInbox() async throws {
        stub("https://example.com/story")
        let inbox = makeViewModel()
        let link = try XCTUnwrap(URL(string: "https://example.com/story"))
        inbox.add(link)
        await inbox.waitUntilIdle()
        let item = try XCTUnwrap(inbox.store.items.first)
        inbox.toggleArchived(item)
        XCTAssertTrue(inbox.visibleItems.isEmpty)

        inbox.add(link)

        XCTAssertEqual(inbox.store.items.first?.isArchived, false)
        XCTAssertEqual(inbox.visibleItems.map(\.id), [item.id])
    }

    func test_extractionErrorsAreShownWithTheMappedMessage() async throws {
        extractResults["https://example.com/locked"] = .failure(ArticleServiceError(.paywalled, detail: "raw"))
        let inbox = makeViewModel()

        try inbox.add(XCTUnwrap(URL(string: "https://example.com/locked")))
        await inbox.waitUntilIdle()

        XCTAssertTrue(inbox.store.items.isEmpty)
        XCTAssertEqual(inbox.notice?.kind, .error)
        XCTAssertEqual(inbox.notice?.message, ArticleServiceError(.paywalled).errorDescription)
        XCTAssertNil(inbox.notice?.action)
    }

    func test_pdfLinksOfferToMakeAnAudiobook() async throws {
        let link = try XCTUnwrap(URL(string: "https://example.com/paper.pdf"))
        extractResults[link.absoluteString] = .failure(ArticleServiceError(.pdfDocument))
        let inbox = makeViewModel()

        inbox.add(link)
        await inbox.waitUntilIdle()

        XCTAssertEqual(inbox.notice?.action, .makeAudiobook(link))
    }

    func test_servicesAdditionsPostANotification() async throws {
        stub("https://example.com/story")
        let inbox = makeViewModel()

        try inbox.add(XCTUnwrap(URL(string: "https://example.com/story")), announce: true)
        await inbox.waitUntilIdle()

        XCTAssertEqual(notifications, [InboxViewModel.Message.savedNotificationTitle])
    }

    func test_listenSpeaksTitleAndBodyThroughTheSpeechPath() async throws {
        stub("https://example.com/story", title: "Big Story", text: "Paragraph one.\n\nParagraph two.")
        let inbox = makeViewModel()
        try inbox.add(XCTUnwrap(URL(string: "https://example.com/story")))
        await inbox.waitUntilIdle()
        let item = try XCTUnwrap(inbox.store.items.first)

        inbox.listen(to: item)
        await inbox.waitUntilIdle()

        XCTAssertEqual(spoken, ["Big Story\n\nParagraph one.\n\nParagraph two."])
        XCTAssertEqual(inbox.listeningItemID, item.id)
    }

    func test_playbackProgressIsSavedAndFinishingMarksTheItemRead() async throws {
        stub("https://example.com/story", title: "Big Story", text: "Body.")
        let inbox = makeViewModel()
        try inbox.add(XCTUnwrap(URL(string: "https://example.com/story")))
        await inbox.waitUntilIdle()
        let item = try XCTUnwrap(inbox.store.items.first)
        let text = InboxViewModel.listeningText(title: "Big Story", body: "Body.")
        inbox.listen(to: item)

        playback.send(InboxPlaybackSample(spokenText: "Older clip", progress: 1, completed: true, isSpeechSession: true))
        playback.send(InboxPlaybackSample(spokenText: text, progress: 0.7, completed: false, isSpeechSession: true))
        XCTAssertEqual(inbox.store.items.first?.progress, 0)
        playback.send(InboxPlaybackSample(spokenText: text, progress: 0, completed: true, isSpeechSession: true))
        playback.send(InboxPlaybackSample(spokenText: text, progress: 0, completed: false, isSpeechSession: true))
        XCTAssertEqual(inbox.store.items.first?.progress, 0)
        playback.send(InboxPlaybackSample(spokenText: text, progress: 0.4, completed: false, isSpeechSession: true))
        XCTAssertEqual(inbox.store.items.first?.progress, 0.4)
        playback.send(InboxPlaybackSample(spokenText: text, progress: 0.41, completed: false, isSpeechSession: true))
        XCTAssertEqual(inbox.store.items.first?.progress, 0.4)
        playback.send(InboxPlaybackSample(spokenText: text, progress: 1, completed: true, isSpeechSession: true))

        XCTAssertEqual(inbox.store.items.first?.isFinished, true)
        XCTAssertNil(inbox.listeningItemID)
        XCTAssertTrue(inbox.visibleItems.isEmpty)
    }

    func test_otherPlaybackEndsTheListeningSession() async throws {
        stub("https://example.com/story", title: "Big Story", text: "Body.")
        let inbox = makeViewModel()
        try inbox.add(XCTUnwrap(URL(string: "https://example.com/story")))
        await inbox.waitUntilIdle()
        let item = try XCTUnwrap(inbox.store.items.first)
        let text = InboxViewModel.listeningText(title: "Big Story", body: "Body.")
        inbox.listen(to: item)

        playback.send(InboxPlaybackSample(spokenText: text, progress: 0, completed: false, isSpeechSession: true))
        playback.send(InboxPlaybackSample(spokenText: text, progress: 0.2, completed: false, isSpeechSession: true))
        playback.send(InboxPlaybackSample(spokenText: text, progress: 0.9, completed: false, isSpeechSession: false))
        playback.send(InboxPlaybackSample(spokenText: text, progress: 0.95, completed: false, isSpeechSession: true))

        XCTAssertNil(inbox.listeningItemID)
        XCTAssertEqual(inbox.store.items.first?.progress, 0.2)
    }

    func test_makeAudiobookCreatesAndStartsTheBook() async throws {
        stub("https://example.com/story")
        estimate = try .success(estimateResponse(bookID: "book-1", duplicateOf: nil))
        let inbox = makeViewModel()
        try inbox.add(XCTUnwrap(URL(string: "https://example.com/story")))
        await inbox.waitUntilIdle()
        let item = try XCTUnwrap(inbox.store.items.first)

        inbox.makeAudiobook(from: item)
        XCTAssertTrue(inbox.isMakingAudiobook(item))
        await inbox.waitUntilIdle()

        XCTAssertFalse(inbox.isMakingAudiobook(item))
        XCTAssertEqual(createdURLs, [item.url])
        XCTAssertEqual(narrations.first, AudiobookNarration(voice: "af_bella", speed: 1.25))
        XCTAssertEqual(started, ["book-1"])
        XCTAssertEqual(libraryRefreshes, 1)
        XCTAssertEqual(inbox.notice?.action, .showLibrary)
    }

    func test_makeAudiobookDiscardsDuplicatesAndOffersTheExistingBook() async throws {
        stub("https://example.com/story")
        estimate = try .success(estimateResponse(bookID: "book-2", duplicateOf: "book-1"))
        let inbox = makeViewModel()
        try inbox.add(XCTUnwrap(URL(string: "https://example.com/story")))
        await inbox.waitUntilIdle()

        try inbox.makeAudiobook(from: XCTUnwrap(inbox.store.items.first))
        await inbox.waitUntilIdle()

        XCTAssertEqual(discarded, ["book-2"])
        XCTAssertTrue(started.isEmpty)
        XCTAssertEqual(inbox.notice?.action, .openAudiobook("book-1"))
        inbox.perform(.openAudiobook("book-1"))
        XCTAssertEqual(openedBooks, ["book-1"])
    }

    func test_makeAudiobookDiscardsTheBookWhenStartFails() async throws {
        stub("https://example.com/story")
        estimate = try .success(estimateResponse(bookID: "book-3", duplicateOf: nil))
        startError = AudiobookServiceError.uploadFailed("Failed to start processing")
        let inbox = makeViewModel()
        try inbox.add(XCTUnwrap(URL(string: "https://example.com/story")))
        await inbox.waitUntilIdle()

        try inbox.makeAudiobook(from: XCTUnwrap(inbox.store.items.first))
        await inbox.waitUntilIdle()

        XCTAssertEqual(discarded, ["book-3"])
        XCTAssertEqual(inbox.notice, InboxNotice(message: "Failed to start processing", kind: .error))
    }

    func test_itemActionsUseTheStoredArticle() async throws {
        stub("https://example.com/story", title: "Big Story", text: "Body.")
        let inbox = makeViewModel()
        try inbox.add(XCTUnwrap(URL(string: "https://example.com/story")))
        await inbox.waitUntilIdle()
        let item = try XCTUnwrap(inbox.store.items.first)

        inbox.copyText(of: item)
        inbox.openOriginal(item)
        inbox.delete(item)

        XCTAssertEqual(copied, ["Big Story\n\nBody."])
        XCTAssertEqual(opened, [item.url])
        XCTAssertTrue(inbox.store.items.isEmpty)
        XCTAssertTrue(inbox.isEmpty)
    }

    func test_pastingWithoutALinkExplainsWhatToDo() {
        let inbox = makeViewModel()

        inbox.pasteLink(nil)

        XCTAssertEqual(inbox.notice?.message, InboxViewModel.Message.noPastedLink)
    }

    func test_eraseAllClearsTheStore() async throws {
        stub("https://example.com/story")
        let inbox = makeViewModel()
        try inbox.add(XCTUnwrap(URL(string: "https://example.com/story")))
        await inbox.waitUntilIdle()

        try inbox.eraseAll()

        XCTAssertTrue(inbox.store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func test_countsFollowEachFilter() async throws {
        stub("https://example.com/a")
        stub("https://example.com/b")
        let inbox = makeViewModel()
        try inbox.add(XCTUnwrap(URL(string: "https://example.com/a")))
        try inbox.add(XCTUnwrap(URL(string: "https://example.com/b")))
        await inbox.waitUntilIdle()
        try inbox.toggleArchived(XCTUnwrap(inbox.store.items.first))

        XCTAssertEqual(inbox.count(for: .unread), 1)
        XCTAssertEqual(inbox.count(for: .archived), 1)
        XCTAssertEqual(inbox.count(for: .all), 2)
    }
}
