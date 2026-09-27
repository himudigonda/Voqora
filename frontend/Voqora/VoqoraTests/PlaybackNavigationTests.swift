@testable import Voqora
import XCTest

@MainActor
final class PlaybackNavigationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PlaybackNavigationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_streamSeekWhilePausedMovesThePositionWithoutStartingPlayback() {
        let audio = AudioService(startingEngine: false)
        audio.prepareForStream()
        audio.playChunk(wav(seconds: 4), volume: 1)
        audio.finishStream()

        audio.seek(toSeconds: 3)

        XCTAssertFalse(audio.isPlaying)
        XCTAssertEqual(audio.currentTime, 3, accuracy: 0.001)
        XCTAssertEqual(audio.progress, 0.75, accuracy: 0.001)
        XCTAssertEqual(audio.duration, 4, accuracy: 0.001)
    }

    func test_seekClampsToTheEndOfTheClipAndPercentageSeekUsesTheSameTimeline() {
        let audio = AudioService(startingEngine: false)
        audio.prepareForStream()
        audio.playChunk(wav(seconds: 2), volume: 1)
        audio.finishStream()

        audio.seek(to: 0.25)
        XCTAssertEqual(audio.currentTime, 0.5, accuracy: 0.001)

        audio.skip(by: 60)
        XCTAssertEqual(audio.currentTime, 2, accuracy: 0.001)
        XCTAssertTrue(audio.playbackCompleted)
    }

    func test_stopKeepsTheLastClipForReplayAndExport() {
        let audio = AudioService(startingEngine: false)
        audio.prepareForStream()
        audio.playChunk(wav(seconds: 1), volume: 1)
        audio.finishStream()

        audio.stop()

        XCTAssertTrue(audio.hasMedia)
        XCTAssertTrue(audio.canExportLastClip)
        XCTAssertEqual(audio.duration, 1, accuracy: 0.001)
    }

    func test_aStoppedSessionCanNoLongerBeCreditedWithACompletion() {
        let audio = AudioService(startingEngine: false)
        let viewModel = AudiobookViewModel(audio: audio)
        let key = "bookPos_stale-session"
        UserDefaults.standard.set(30.0, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        audio.completedSessionID = "stale-session"

        audio.prepareForStream()
        audio.playbackCompleted = true

        XCTAssertNil(audio.completedSessionID)
        XCTAssertEqual(UserDefaults.standard.double(forKey: key), 30, "a speech clip finishing must not clear a book's resume point")
        _ = viewModel
    }

    func test_seekingToTheLiveEdgeOfAStreamKeepsASchedulableSample() {
        let audio = AudioService(startingEngine: false)
        audio.prepareForStream()
        audio.playChunk(wav(seconds: 1), volume: 1)

        audio.seek(toSeconds: 5)

        XCTAssertFalse(audio.playbackCompleted)
        XCTAssertLessThan(audio.currentTime, 1)
    }

    func test_seekWithNothingLoadedIsANoOp() {
        let audio = AudioService(startingEngine: false)
        audio.seek(toSeconds: 10)
        XCTAssertEqual(audio.currentTime, 0)
        XCTAssertFalse(audio.hasMedia)
    }

    func test_stoppingSavesTheResumePointAndNearTheEndClearsIt() {
        let audio = AudioService(startingEngine: false)
        let viewModel = AudiobookViewModel(audio: audio)
        let key = "bookPos_resume-test"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        viewModel.nowPlaying = makeBook(id: "resume-test")
        audio.duration = 100
        audio.currentTime = 42
        viewModel.stopPlayback()
        XCTAssertEqual(UserDefaults.standard.double(forKey: key), 42)

        viewModel.nowPlaying = makeBook(id: "resume-test")
        audio.duration = 100
        audio.currentTime = 98
        viewModel.stopPlayback()
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
    }

    func test_openAudiobookSelectsTheLibraryAndPushesExactlyThatPlayer() {
        let audio = AudioService(startingEngine: false)
        let books = AudiobookViewModel(audio: audio)
        let dashboard = makeDashboard(audio: audio)
        dashboard.audiobookVM = books
        dashboard.selectedTab = "history"
        books.libraryPath = [.player("older")]

        dashboard.openAudiobook("book-a")

        XCTAssertEqual(dashboard.selectedTab, "books")
        XCTAssertEqual(books.libraryPath, [.player("book-a")])

        dashboard.openAudiobook("book-a")
        XCTAssertEqual(books.libraryPath, [.player("book-a")], "repeated opens must not stack duplicate players")

        dashboard.showLibrary()
        XCTAssertEqual(books.libraryPath, [])
    }

    func test_openNowPlayingRoutesToTheActiveSource() {
        let audio = AudioService(startingEngine: false)
        let books = AudiobookViewModel(audio: audio)
        let dashboard = makeDashboard(audio: audio)
        dashboard.audiobookVM = books
        dashboard.selectedTab = "preferences"

        dashboard.openNowPlaying()
        XCTAssertEqual(dashboard.selectedTab, "home")

        books.nowPlaying = makeBook(id: "playing")
        dashboard.openNowPlaying()
        XCTAssertEqual(dashboard.selectedTab, "books")
        XCTAssertEqual(books.libraryPath, [.player("playing")])
    }

    func test_subtitleShowsMeaningfulSectionsOnly() {
        let single = makeBook(id: "s", sections: [section("Attention Is All You Need.pdf", at: 0)])
        XCTAssertEqual(single.subtitle(at: 10), "Narrated by Bella")

        let chaptered = makeBook(id: "c", sections: [section("Introduction", at: 0), section("Results", at: 60)])
        XCTAssertEqual(chaptered.subtitle(at: 10), "Introduction")
        XCTAssertEqual(chaptered.subtitle(at: 61), "Results")

        let echoed = makeBook(id: "e", sections: [section("Book Title.pdf", at: 0), section("Two", at: 60)])
        XCTAssertEqual(echoed.subtitle(at: 1), "Narrated by Bella")
    }

    func test_listingDurationsReadLikeTheSystem() {
        XCTAssertEqual(DurationFormatter.listing(2457), "41 min")
        XCTAssertEqual(DurationFormatter.listing(3600), "1 hr")
        XCTAssertEqual(DurationFormatter.listing(5040), "1 hr 24 min")
        XCTAssertEqual(DurationFormatter.listing(20), "20 sec")
    }

    func test_voiceNameDropsTheLanguagePrefix() {
        XCTAssertEqual(DashboardViewModel.voiceName(for: "af_bella"), "Bella")
        XCTAssertEqual(DashboardViewModel.voiceName(for: "bm_george"), "George")
    }

    private func makeDashboard(audio: AudioService) -> DashboardViewModel {
        DashboardViewModel(
            backend: BackendService(),
            system: SystemService(),
            audio: audio,
            history: HistoryManager(),
            startsBackgroundWork: false,
            defaults: defaults
        )
    }

    private func wav(seconds: Double) -> Data {
        Data(count: 44) + Data(count: Int(seconds * 24000) * 2)
    }

    private func section(_ title: String, at time: Double) -> AudiobookSection {
        AudiobookSection(title: title, startPage: Int(time) + 1, endPage: Int(time) + 1, startTime: time)
    }

    private func makeBook(id: String, sections: [AudiobookSection] = []) -> Audiobook {
        Audiobook(
            bookID: id,
            title: id == "e" ? "Book Title.pdf" : "Test Book.pdf",
            createdAt: "2026-09-27T00:00:00Z",
            pageCount: 1,
            status: "done",
            phaseProgress: PhaseProgress(pageDone: 1, pageTotal: 1),
            sections: sections,
            pageToTime: [:],
            totalAudioSeconds: 120,
            failedPages: [],
            estimated: nil,
            actual: nil,
            engine: "kokoro",
            voice: "af_bella",
            speed: 1,
            usesGeminiCleanup: false,
            budget: nil,
            error: nil
        )
    }
}
