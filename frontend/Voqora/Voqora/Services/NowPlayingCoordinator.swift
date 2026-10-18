import AppKit
import Foundation

@MainActor
protocol NowPlayingInfoPublishing: AnyObject {
    func publish(_ state: NowPlayingState, artwork: NSImage?)
    func clear()
}

@MainActor
protocol RemoteCommandRegistering: AnyObject {
    func activate(skipInterval: TimeInterval, handler: @escaping @MainActor (NowPlayingCommandRequest) -> Bool)
    func deactivate()
    func setAvailable(_ commands: Set<NowPlayingCommand>)
}

@MainActor
protocol NowPlayingArtworkProviding: AnyObject {
    func artwork(for media: NowPlayingMedia) async -> NSImage?
}

@MainActor
protocol AudioOutputRouteMonitoring: AnyObject {
    var onRouteLost: (() -> Void)? { get set }
    func start()
}

@MainActor
protocol NowPlayingControls: AnyObject {
    func play()
    func pause()
    func togglePlayPause()
    func stop()
    func skip(by seconds: TimeInterval)
    func seek(to seconds: TimeInterval)
    func nextTrack()
    func previousTrack()
}

final class NowPlayingCoordinator {
    static let skipInterval: TimeInterval = 15

    weak var controls: NowPlayingControls?
    private(set) var isEnabled = false
    private(set) var latestState: NowPlayingState?
    private(set) var artworkTask: Task<Void, Never>?

    private let infoCenter: NowPlayingInfoPublishing
    private let commandCenter: RemoteCommandRegistering
    private let artworkProvider: NowPlayingArtworkProviding
    private let routeMonitor: AudioOutputRouteMonitoring
    private let now: () -> Date

    private var publishedState: NowPlayingState?
    private var publishedAt: Date?
    private var enabledCommands: Set<NowPlayingCommand>?
    private var artworkMedia: NowPlayingMedia?
    private var artwork: NSImage?

    init(
        infoCenter: NowPlayingInfoPublishing,
        commandCenter: RemoteCommandRegistering,
        artworkProvider: NowPlayingArtworkProviding,
        routeMonitor: AudioOutputRouteMonitoring,
        now: @escaping () -> Date = { Date() }
    ) {
        self.infoCenter = infoCenter
        self.commandCenter = commandCenter
        self.artworkProvider = artworkProvider
        self.routeMonitor = routeMonitor
        self.now = now
        routeMonitor.onRouteLost = { [weak self] in
            self?.handleRouteLost()
        }
    }

    func start(mediaKeysEnabled: Bool) {
        routeMonitor.start()
        setEnabled(mediaKeysEnabled)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        VoqoraLog.info("NowPlaying", "System media controls changed", ["enabled": "\(enabled)"])
        if enabled {
            commandCenter.activate(skipInterval: Self.skipInterval) { [weak self] request in
                self?.handle(request) ?? false
            }
            apply(latestState)
        } else {
            clearPublished()
            commandCenter.deactivate()
            enabledCommands = nil
        }
    }

    func render(_ state: NowPlayingState?) {
        latestState = state
        guard isEnabled else { return }
        apply(state)
    }

    @discardableResult
    func handle(_ request: NowPlayingCommandRequest) -> Bool {
        guard isEnabled, let state = latestState, let controls,
              Self.availableCommands(for: state).contains(request.command)
        else { return false }
        switch request.command {
        case .play:
            controls.play()
        case .pause:
            controls.pause()
        case .togglePlayPause:
            controls.togglePlayPause()
        case .stop:
            controls.stop()
        case .skipForward:
            controls.skip(by: Self.skipInterval)
        case .skipBackward:
            controls.skip(by: -Self.skipInterval)
        case .changePlaybackPosition:
            guard let position = request.position, position.isFinite else { return false }
            controls.seek(to: min(max(0, position), state.timeline.duration))
        case .nextTrack:
            controls.nextTrack()
        case .previousTrack:
            controls.previousTrack()
        }
        VoqoraLog.debug("NowPlaying", "Handled system media command", ["command": "\(request.command)"])
        return true
    }

    static func availableCommands(for state: NowPlayingState?) -> Set<NowPlayingCommand> {
        guard let state else { return [] }
        var commands: Set<NowPlayingCommand> = [.play, .pause, .togglePlayPause, .stop, .skipForward, .skipBackward]
        if state.timeline.duration > 0 {
            commands.insert(.changePlaybackPosition)
        }
        if state.canNavigateTracks {
            commands.formUnion([.nextTrack, .previousTrack])
        }
        return commands
    }

    private func apply(_ state: NowPlayingState?) {
        guard let state else {
            clearPublished()
            return
        }
        updateAvailableCommands(Self.availableCommands(for: state))
        loadArtworkIfNeeded(for: state.media)
        let currentTime = now()
        guard NowPlayingRefreshPolicy.needsRefresh(published: publishedState, publishedAt: publishedAt, next: state, now: currentTime) else { return }
        publish(state, at: currentTime)
    }

    private func publish(_ state: NowPlayingState, at time: Date) {
        infoCenter.publish(state, artwork: artwork)
        publishedState = state
        publishedAt = time
    }

    private func clearPublished() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkMedia = nil
        artwork = nil
        updateAvailableCommands([])
        guard publishedState != nil else { return }
        publishedState = nil
        publishedAt = nil
        infoCenter.clear()
    }

    private func updateAvailableCommands(_ commands: Set<NowPlayingCommand>) {
        guard commands != enabledCommands else { return }
        enabledCommands = commands
        commandCenter.setAvailable(commands)
    }

    private func loadArtworkIfNeeded(for media: NowPlayingMedia) {
        guard media != artworkMedia else { return }
        artworkMedia = media
        artwork = nil
        artworkTask?.cancel()
        let provider = artworkProvider
        artworkTask = Task { [weak self] in
            let loaded = await provider.artwork(for: media)
            guard let self, !Task.isCancelled, artworkMedia == media, let loaded else { return }
            artwork = loaded
            guard isEnabled, let latestState, latestState.media == media else { return }
            publish(latestState, at: now())
        }
    }

    private func handleRouteLost() {
        guard latestState?.timeline.isPlaying == true, let controls else { return }
        VoqoraLog.info("NowPlaying", "Audio output disconnected, pausing playback")
        controls.pause()
    }
}
