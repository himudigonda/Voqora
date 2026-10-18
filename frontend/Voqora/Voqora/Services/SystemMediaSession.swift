import Combine
import Foundation

final class SystemMediaSession: NowPlayingControls {
    private let dashboard: DashboardViewModel
    private let audiobooks: AudiobookViewModel
    private let coordinator: NowPlayingCoordinator
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    private var audio: AudioService {
        dashboard.audio
    }

    init(
        dashboard: DashboardViewModel,
        audiobooks: AudiobookViewModel,
        coordinator: NowPlayingCoordinator,
        defaults: UserDefaults = .standard
    ) {
        self.dashboard = dashboard
        self.audiobooks = audiobooks
        self.coordinator = coordinator
        self.defaults = defaults
    }

    static func live(dashboard: DashboardViewModel, audiobooks: AudiobookViewModel) -> SystemMediaSession {
        let coordinator = NowPlayingCoordinator(
            infoCenter: SystemNowPlayingInfoCenter(),
            commandCenter: SystemRemoteCommandCenter(),
            artworkProvider: BackendNowPlayingArtwork(),
            routeMonitor: CoreAudioOutputRouteMonitor()
        )
        return SystemMediaSession(dashboard: dashboard, audiobooks: audiobooks, coordinator: coordinator)
    }

    func start() {
        coordinator.controls = self
        coordinator.render(currentState())
        coordinator.start(mediaKeysEnabled: NowPlayingPreferences.respondsToMediaKeys(defaults))
        observePlayback()
        observePreference()
    }

    func currentState() -> NowPlayingState? {
        let timeline = NowPlayingTimeline(
            elapsed: audio.currentTime,
            duration: audio.duration,
            rate: Double(audio.playbackRate),
            isPlaying: audio.isPlaying
        )
        if let book = audiobooks.nowPlaying {
            return .audiobook(
                bookID: book.bookID,
                title: book.displayTitle,
                chapters: audiobooks.chapters(for: book),
                timeline: timeline
            )
        }
        guard audio.hasMedia, dashboard.status == .speaking || dashboard.status == .paused else { return nil }
        return .selectedText(sentenceCount: dashboard.speechFollower.document.lines.count, timeline: timeline)
    }

    func play() {
        guard !audio.isPlaying else { return }
        dashboard.togglePlayback()
    }

    func pause() {
        guard audio.isPlaying else { return }
        dashboard.togglePlayback()
    }

    func togglePlayPause() {
        dashboard.togglePlayback()
    }

    func stop() {
        dashboard.stopPlayback()
    }

    func skip(by seconds: TimeInterval) {
        if audiobooks.nowPlaying != nil {
            audiobooks.skip(by: seconds)
        } else {
            dashboard.skipSpeech(by: seconds)
        }
    }

    func seek(to seconds: TimeInterval) {
        if audiobooks.nowPlaying != nil {
            audiobooks.seek(toSeconds: seconds)
        } else {
            audio.seek(toSeconds: seconds)
        }
    }

    func nextTrack() {
        if let book = audiobooks.nowPlaying {
            audiobooks.jumpToNextSection(in: book)
        } else if let start = PlaybackTrackNavigation.nextStart(in: sentenceStarts, after: audio.currentTime) {
            audio.seek(toSeconds: start)
        }
    }

    func previousTrack() {
        if let book = audiobooks.nowPlaying {
            audiobooks.jumpToPreviousSection(in: book)
        } else {
            audio.seek(toSeconds: PlaybackTrackNavigation.previousStart(in: sentenceStarts, before: audio.currentTime))
        }
    }

    private var sentenceStarts: [TimeInterval] {
        let follower = dashboard.speechFollower
        return follower.document.lines.map { follower.startTime(of: $0) }
    }

    private func observePlayback() {
        let triggers: [AnyPublisher<Void, Never>] = [
            audio.$isPlaying.asTrigger,
            audio.$currentTime.asTrigger,
            audio.$duration.asTrigger,
            audio.$playbackRate.asTrigger,
            audiobooks.$nowPlaying.asTrigger,
            audiobooks.$chapters.asTrigger,
            dashboard.$status.asTrigger,
            dashboard.speechFollower.$document.asTrigger,
        ]
        Publishers.MergeMany(triggers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                coordinator.render(currentState())
            }
            .store(in: &cancellables)
    }

    private func observePreference() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .map { [defaults] _ in NowPlayingPreferences.respondsToMediaKeys(defaults) }
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.coordinator.setEnabled(enabled)
            }
            .store(in: &cancellables)
    }
}

private extension Publisher where Failure == Never {
    var asTrigger: AnyPublisher<Void, Never> {
        map { _ in () }.eraseToAnyPublisher()
    }
}
