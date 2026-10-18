import AppKit
@testable import Voqora
import XCTest

@MainActor
final class SystemMediaSessionTests: XCTestCase {
    private let suiteName = "SystemMediaSessionTests.runtime"
    private let bookID = "session-book"
    private var defaults: UserDefaults!
    private var audio: AudioService!
    private var dashboard: DashboardViewModel!
    private var audiobooks: AudiobookViewModel!
    private var infoCenter: SessionInfoCenter!
    private var commandCenter: SessionCommandCenter!
    private var session: SystemMediaSession!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        audio = AudioService(startingEngine: false)
        dashboard = DashboardViewModel(
            backend: BackendService(),
            system: SystemService(),
            audio: audio,
            history: HistoryManager(),
            startsBackgroundWork: false,
            defaults: defaults
        )
        audiobooks = AudiobookViewModel(audio: audio)
        dashboard.audiobookVM = audiobooks
        infoCenter = SessionInfoCenter()
        commandCenter = SessionCommandCenter()
        let coordinator = NowPlayingCoordinator(
            infoCenter: infoCenter,
            commandCenter: commandCenter,
            artworkProvider: SilentArtwork(),
            routeMonitor: SilentRouteMonitor()
        )
        session = SystemMediaSession(dashboard: dashboard, audiobooks: audiobooks, coordinator: coordinator, defaults: defaults)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "bookPos_\(bookID)")
        defaults.removePersistentDomain(forName: suiteName)
        session = nil
        commandCenter = nil
        infoCenter = nil
        audiobooks = nil
        dashboard = nil
        audio = nil
        defaults = nil
        super.tearDown()
    }

    func test_thereIsNothingToShowWithoutMedia() {
        XCTAssertNil(session.currentState())
    }

    func test_finishedOrIdleSelectedTextIsNotShown() {
        loadClip(seconds: 4)
        dashboard.status = .ready

        XCTAssertNil(session.currentState())
    }

    func test_pausedSelectedTextIsShownWithSentenceNavigation() throws {
        loadClip(seconds: 4)
        dashboard.speechFollower.follow(spokenText: "First part here. Second part here. Third part here.")
        dashboard.status = .paused

        let state = try XCTUnwrap(session.currentState())

        XCTAssertEqual(state.media, .selectedText)
        XCTAssertEqual(state.title, "Selected text")
        XCTAssertTrue(state.canNavigateTracks)
        XCTAssertFalse(state.timeline.isPlaying)
        XCTAssertEqual(state.timeline.duration, 4, accuracy: 0.001)
    }

    func test_nextAndPreviousTrackMoveBetweenSentencesOfSelectedText() throws {
        loadClip(seconds: 4)
        dashboard.speechFollower.follow(spokenText: "First part here. Second part here. Third part here.")
        dashboard.status = .paused
        let lines = dashboard.speechFollower.document.lines
        XCTAssertGreaterThanOrEqual(lines.count, 3)
        let second = try XCTUnwrap(lines.dropFirst().first)

        session.nextTrack()
        XCTAssertEqual(audio.currentTime, dashboard.speechFollower.startTime(of: second), accuracy: 0.001)

        session.previousTrack()
        XCTAssertEqual(audio.currentTime, 0, accuracy: 0.001)
    }

    func test_loadedAudiobookIsShownWithItsCurrentSection() throws {
        audiobooks.nowPlaying = makeBook()
        audio.duration = 120
        audio.currentTime = 70

        let state = try XCTUnwrap(session.currentState())

        XCTAssertEqual(state.media, .audiobook(bookID: bookID))
        XCTAssertEqual(state.title, "Session Book")
        XCTAssertEqual(state.section, NowPlayingSection(title: "Part Two", index: 1, count: 2))
        XCTAssertTrue(state.canNavigateTracks)
    }

    func test_audiobookTrackAndSeekCommandsMoveThroughTheBook() {
        loadClip(seconds: 4)
        audiobooks.nowPlaying = makeBook()

        session.nextTrack()
        XCTAssertEqual(audio.currentTime, 2, accuracy: 0.001)

        session.seek(to: 3)
        XCTAssertEqual(audio.currentTime, 3, accuracy: 0.001)

        session.skip(by: -15)
        XCTAssertEqual(audio.currentTime, 0, accuracy: 0.001)
    }

    func test_stopClearsTheAudiobook() {
        audiobooks.nowPlaying = makeBook()

        session.stop()

        XCTAssertNil(audiobooks.nowPlaying)
        XCTAssertNil(session.currentState())
    }

    func test_startedSessionPublishesPlaybackAndFollowsTheMediaKeysPreference() async {
        session.start()
        XCTAssertTrue(commandCenter.isActive)

        audiobooks.nowPlaying = makeBook()
        await waitUntil { infoCenter.published.last?.media == .audiobook(bookID: bookID) }
        XCTAssertEqual(infoCenter.published.last?.media, .audiobook(bookID: bookID))

        defaults.set(false, forKey: NowPlayingPreferences.respondToMediaKeysKey)
        await waitUntil { !commandCenter.isActive }
        XCTAssertFalse(commandCenter.isActive)
        XCTAssertEqual(infoCenter.clearCount, 1)
    }

    private func waitUntil(_ condition: () -> Bool, attempts: Int = 100) async {
        for _ in 0 ..< attempts {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func loadClip(seconds: Double) {
        audio.prepareForStream()
        audio.playChunk(Data(count: 44) + Data(count: Int(seconds * 24000) * 2), volume: 1)
        audio.finishStream()
    }

    private func makeBook() -> Audiobook {
        Audiobook(
            bookID: bookID,
            title: "Session_Book.pdf",
            createdAt: "2026-10-01T00:00:00Z",
            pageCount: 2,
            status: "done",
            phaseProgress: PhaseProgress(pageDone: 2, pageTotal: 2),
            sections: [
                AudiobookSection(title: "Part One", startPage: 1, endPage: 1, startTime: 0),
                AudiobookSection(title: "Part Two", startPage: 2, endPage: 2, startTime: 2),
            ],
            pageToTime: [:],
            totalAudioSeconds: 4,
            failedPages: [],
            estimated: nil,
            actual: nil,
            engine: "kokoro",
            voice: "af_bella",
            speed: 1,
            usesLLMCleanup: false,
            budget: nil,
            error: nil
        )
    }
}

@MainActor
private final class SessionInfoCenter: NowPlayingInfoPublishing {
    private(set) var published: [NowPlayingState] = []
    private(set) var clearCount = 0

    func publish(_ state: NowPlayingState, artwork _: NSImage?) {
        published.append(state)
    }

    func clear() {
        clearCount += 1
    }
}

@MainActor
private final class SessionCommandCenter: RemoteCommandRegistering {
    private(set) var isActive = false

    func activate(skipInterval _: TimeInterval, handler _: @escaping @MainActor (NowPlayingCommandRequest) -> Bool) {
        isActive = true
    }

    func deactivate() {
        isActive = false
    }

    func setAvailable(_: Set<NowPlayingCommand>) {}
}

@MainActor
private final class SilentArtwork: NowPlayingArtworkProviding {
    func artwork(for _: NowPlayingMedia) async -> NSImage? {
        nil
    }
}

@MainActor
private final class SilentRouteMonitor: AudioOutputRouteMonitoring {
    var onRouteLost: (() -> Void)?

    func start() {}
}
