import AppKit
@testable import Voqora
import XCTest

@MainActor
final class NowPlayingCoordinatorTests: XCTestCase {
    private var infoCenter: RecordingInfoCenter!
    private var commandCenter: RecordingCommandCenter!
    private var artwork: StubArtwork!
    private var routeMonitor: StubRouteMonitor!
    private var controls: RecordingControls!
    private var clock: TestClock!
    private var coordinator: NowPlayingCoordinator!

    override func setUp() {
        super.setUp()
        let info = RecordingInfoCenter()
        let commands = RecordingCommandCenter()
        let stubArtwork = StubArtwork()
        let monitor = StubRouteMonitor()
        let recorder = RecordingControls()
        let testClock = TestClock()
        let subject = NowPlayingCoordinator(
            infoCenter: info,
            commandCenter: commands,
            artworkProvider: stubArtwork,
            routeMonitor: monitor,
            now: { testClock.now }
        )
        subject.controls = recorder
        infoCenter = info
        commandCenter = commands
        artwork = stubArtwork
        routeMonitor = monitor
        controls = recorder
        clock = testClock
        coordinator = subject
    }

    override func tearDown() {
        coordinator = nil
        controls = nil
        routeMonitor = nil
        artwork = nil
        commandCenter = nil
        infoCenter = nil
        clock = nil
        super.tearDown()
    }

    func test_startRegistersCommandsWithFifteenSecondSkipsAndWatchesTheOutputRoute() {
        coordinator.start(mediaKeysEnabled: true)

        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertEqual(commandCenter.skipInterval, 15)
        XCTAssertTrue(commandCenter.isActive)
        XCTAssertTrue(routeMonitor.started)
    }

    func test_startWithMediaKeysOffWatchesTheRouteButRegistersNothing() {
        coordinator.start(mediaKeysEnabled: false)
        coordinator.render(audiobookState())

        XCTAssertFalse(commandCenter.isActive)
        XCTAssertTrue(routeMonitor.started)
        XCTAssertTrue(infoCenter.published.isEmpty)
    }

    func test_renderPublishesAudiobookInfoAndEnablesSectionNavigation() {
        coordinator.start(mediaKeysEnabled: true)
        let state = audiobookState()

        coordinator.render(state)

        XCTAssertEqual(infoCenter.published, [state])
        XCTAssertEqual(state.section?.title, "Chapter One")
        XCTAssertEqual(commandCenter.available, Set(NowPlayingCommand.allCases))
    }

    func test_selectedTextWithOneSentenceLeavesTrackCommandsDisabled() {
        coordinator.start(mediaKeysEnabled: true)

        coordinator.render(.selectedText(sentenceCount: 1, timeline: timeline(elapsed: 1, duration: 8)))

        XCTAssertEqual(infoCenter.published.last?.title, "Selected text")
        XCTAssertFalse(commandCenter.available.contains(.nextTrack))
        XCTAssertFalse(commandCenter.available.contains(.previousTrack))
        XCTAssertTrue(commandCenter.available.contains(.changePlaybackPosition))
    }

    func test_steadyPlaybackIsNotRepublishedButASeekIs() {
        coordinator.start(mediaKeysEnabled: true)
        coordinator.render(audiobookState(elapsed: 110))

        clock.advance(by: 5)
        coordinator.render(audiobookState(elapsed: 115.2))
        XCTAssertEqual(infoCenter.published.count, 1)

        coordinator.render(audiobookState(elapsed: 160))
        XCTAssertEqual(infoCenter.published.count, 2)
        XCTAssertEqual(infoCenter.published.last?.timeline.elapsed, 160)
    }

    func test_pausingAndSectionChangesRepublish() {
        coordinator.start(mediaKeysEnabled: true)
        coordinator.render(audiobookState(elapsed: 110))

        coordinator.render(audiobookState(elapsed: 110, isPlaying: false))
        XCTAssertEqual(infoCenter.published.last?.timeline.isPlaying, false)

        coordinator.render(audiobookState(elapsed: 210, isPlaying: false))
        XCTAssertEqual(infoCenter.published.last?.section?.title, "Chapter Two")
        XCTAssertEqual(infoCenter.published.count, 3)
    }

    func test_stoppingClearsNowPlayingOnceAndDisablesCommands() {
        coordinator.start(mediaKeysEnabled: true)
        coordinator.render(audiobookState())

        coordinator.render(nil)
        coordinator.render(nil)

        XCTAssertEqual(infoCenter.clearCount, 1)
        XCTAssertTrue(commandCenter.available.isEmpty)
    }

    func test_commandsDriveThePlaybackControls() {
        coordinator.start(mediaKeysEnabled: true)
        coordinator.render(audiobookState())

        for command in [NowPlayingCommand.play, .pause, .togglePlayPause, .skipForward, .skipBackward, .nextTrack, .previousTrack, .stop] {
            XCTAssertTrue(commandCenter.send(command), "\(command) should be handled")
        }

        XCTAssertEqual(controls.calls, [.play, .pause, .toggle, .skip(15), .skip(-15), .next, .previous, .stop])
    }

    func test_changePlaybackPositionIsValidatedAndClamped() {
        coordinator.start(mediaKeysEnabled: true)
        coordinator.render(audiobookState())

        XCTAssertTrue(commandCenter.send(.changePlaybackPosition, position: 42))
        XCTAssertTrue(commandCenter.send(.changePlaybackPosition, position: 9000))
        XCTAssertTrue(commandCenter.send(.changePlaybackPosition, position: -3))
        XCTAssertFalse(commandCenter.send(.changePlaybackPosition, position: nil))
        XCTAssertFalse(commandCenter.send(.changePlaybackPosition, position: .nan))

        XCTAssertEqual(controls.calls, [.seek(42), .seek(300), .seek(0)])
    }

    func test_commandsAreRejectedWithoutMedia() {
        coordinator.start(mediaKeysEnabled: true)

        XCTAssertFalse(commandCenter.send(.play))
        XCTAssertFalse(commandCenter.send(.skipForward))
        XCTAssertTrue(controls.calls.isEmpty)
    }

    func test_trackCommandsAreRejectedWhenThereIsNothingToNavigate() {
        coordinator.start(mediaKeysEnabled: true)
        coordinator.render(.selectedText(sentenceCount: 1, timeline: timeline(elapsed: 1, duration: 8)))

        XCTAssertFalse(commandCenter.send(.nextTrack))
        XCTAssertFalse(commandCenter.send(.previousTrack))
        XCTAssertTrue(controls.calls.isEmpty)
    }

    func test_turningMediaKeysOffUnregistersAndClearsThenOnRestoresTheLatestState() {
        coordinator.start(mediaKeysEnabled: true)
        coordinator.render(audiobookState())

        coordinator.setEnabled(false)
        coordinator.render(audiobookState(elapsed: 150))

        XCTAssertFalse(commandCenter.isActive)
        XCTAssertEqual(infoCenter.clearCount, 1)
        XCTAssertEqual(infoCenter.published.count, 1)
        XCTAssertFalse(coordinator.handle(NowPlayingCommandRequest(command: .play)))

        coordinator.setEnabled(true)

        XCTAssertTrue(commandCenter.isActive)
        XCTAssertEqual(infoCenter.published.last?.timeline.elapsed, 150)
    }

    func test_losingTheOutputRoutePausesOnlyWhilePlaying() {
        coordinator.start(mediaKeysEnabled: false)

        coordinator.render(audiobookState(isPlaying: false))
        routeMonitor.loseRoute()
        XCTAssertTrue(controls.calls.isEmpty)

        coordinator.render(audiobookState(isPlaying: true))
        routeMonitor.loseRoute()
        XCTAssertEqual(controls.calls, [.pause])
    }

    func test_coverArtworkIsLoadedOncePerBookAndRepublished() async {
        artwork.image = NSImage(size: NSSize(width: 4, height: 4))
        coordinator.start(mediaKeysEnabled: true)

        coordinator.render(audiobookState(elapsed: 110))
        coordinator.render(audiobookState(elapsed: 110.1))
        _ = await coordinator.artworkTask?.value

        XCTAssertEqual(artwork.requests, [.audiobook(bookID: "book-1")])
        XCTAssertEqual(infoCenter.published.count, 2)
        XCTAssertNil(infoCenter.artworks.first ?? nil)
        XCTAssertNotNil(infoCenter.artworks.last ?? nil)
    }

    private func timeline(elapsed: TimeInterval, duration: TimeInterval = 300, isPlaying: Bool = true) -> NowPlayingTimeline {
        NowPlayingTimeline(elapsed: elapsed, duration: duration, rate: 1, isPlaying: isPlaying)
    }

    private func audiobookState(elapsed: TimeInterval = 110, isPlaying: Bool = true) -> NowPlayingState {
        .audiobook(
            bookID: "book-1",
            title: "Test Book",
            chapters: [
                AudiobookSection(title: "Opening", startPage: 1, endPage: 1, startTime: 0),
                AudiobookSection(title: "Chapter One", startPage: 2, endPage: 2, startTime: 100),
                AudiobookSection(title: "Chapter Two", startPage: 3, endPage: 3, startTime: 200),
            ],
            timeline: timeline(elapsed: elapsed, isPlaying: isPlaying)
        )
    }
}

@MainActor
private final class TestClock {
    private(set) var now = Date(timeIntervalSince1970: 1000)

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

@MainActor
private final class RecordingInfoCenter: NowPlayingInfoPublishing {
    private(set) var published: [NowPlayingState] = []
    private(set) var artworks: [NSImage?] = []
    private(set) var clearCount = 0

    func publish(_ state: NowPlayingState, artwork: NSImage?) {
        published.append(state)
        artworks.append(artwork)
    }

    func clear() {
        clearCount += 1
    }
}

@MainActor
private final class RecordingCommandCenter: RemoteCommandRegistering {
    private var handler: (@MainActor (NowPlayingCommandRequest) -> Bool)?
    private(set) var skipInterval: TimeInterval?
    private(set) var available: Set<NowPlayingCommand> = []

    var isActive: Bool {
        handler != nil
    }

    func activate(skipInterval: TimeInterval, handler: @escaping @MainActor (NowPlayingCommandRequest) -> Bool) {
        self.skipInterval = skipInterval
        self.handler = handler
    }

    func deactivate() {
        handler = nil
    }

    func setAvailable(_ commands: Set<NowPlayingCommand>) {
        available = commands
    }

    func send(_ command: NowPlayingCommand, position: TimeInterval? = nil) -> Bool {
        handler?(NowPlayingCommandRequest(command: command, position: position)) ?? false
    }
}

@MainActor
private final class StubArtwork: NowPlayingArtworkProviding {
    var image: NSImage?
    private(set) var requests: [NowPlayingMedia] = []

    func artwork(for media: NowPlayingMedia) async -> NSImage? {
        requests.append(media)
        return image
    }
}

@MainActor
private final class StubRouteMonitor: AudioOutputRouteMonitoring {
    var onRouteLost: (() -> Void)?
    private(set) var started = false

    func start() {
        started = true
    }

    func loseRoute() {
        onRouteLost?()
    }
}

@MainActor
private final class RecordingControls: NowPlayingControls {
    enum Call: Equatable {
        case play
        case pause
        case toggle
        case stop
        case skip(TimeInterval)
        case seek(TimeInterval)
        case next
        case previous
    }

    private(set) var calls: [Call] = []

    func play() {
        calls.append(.play)
    }

    func pause() {
        calls.append(.pause)
    }

    func togglePlayPause() {
        calls.append(.toggle)
    }

    func stop() {
        calls.append(.stop)
    }

    func skip(by seconds: TimeInterval) {
        calls.append(.skip(seconds))
    }

    func seek(to seconds: TimeInterval) {
        calls.append(.seek(seconds))
    }

    func nextTrack() {
        calls.append(.next)
    }

    func previousTrack() {
        calls.append(.previous)
    }
}
