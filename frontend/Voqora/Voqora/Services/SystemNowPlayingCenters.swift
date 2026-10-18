import AppKit
import Foundation
import MediaPlayer

final class SystemNowPlayingInfoCenter: NowPlayingInfoPublishing {
    private let center: MPNowPlayingInfoCenter

    init(center: MPNowPlayingInfoCenter = MPNowPlayingInfoCenter.default()) {
        self.center = center
    }

    func publish(_ state: NowPlayingState, artwork: NSImage?) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.title,
            MPMediaItemPropertyArtist: NowPlayingState.artist,
            MPMediaItemPropertyPlaybackDuration: state.timeline.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.timeline.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: state.timeline.isPlaying ? state.timeline.rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let section = state.section {
            info[MPNowPlayingInfoPropertyChapterNumber] = section.index
            info[MPNowPlayingInfoPropertyChapterCount] = section.count
            if let title = section.title {
                info[MPMediaItemPropertyAlbumTitle] = title
            }
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(from: artwork)
        }
        center.nowPlayingInfo = info
        center.playbackState = state.timeline.isPlaying ? .playing : .paused
    }

    func clear() {
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    private nonisolated static func makeArtwork(from image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

final class SystemRemoteCommandCenter: RemoteCommandRegistering {
    private let center: MPRemoteCommandCenter
    private var targets: [(command: MPRemoteCommand, target: Any)] = []

    init(center: MPRemoteCommandCenter = MPRemoteCommandCenter.shared()) {
        self.center = center
    }

    func activate(skipInterval: TimeInterval, handler: @escaping @MainActor (NowPlayingCommandRequest) -> Bool) {
        deactivate()
        let interval = NSNumber(value: skipInterval)
        center.skipForwardCommand.preferredIntervals = [interval]
        center.skipBackwardCommand.preferredIntervals = [interval]
        for command in NowPlayingCommand.allCases {
            let remote = remoteCommand(for: command)
            let target = remote.addTarget(handler: Self.makeHandler(for: command, handler: handler))
            targets.append((command: remote, target: target))
        }
    }

    func deactivate() {
        for registration in targets {
            registration.command.removeTarget(registration.target)
        }
        targets.removeAll()
        setAvailable([])
    }

    func setAvailable(_ commands: Set<NowPlayingCommand>) {
        for command in NowPlayingCommand.allCases {
            remoteCommand(for: command).isEnabled = commands.contains(command)
        }
    }

    private func remoteCommand(for command: NowPlayingCommand) -> MPRemoteCommand {
        switch command {
        case .play: center.playCommand
        case .pause: center.pauseCommand
        case .togglePlayPause: center.togglePlayPauseCommand
        case .stop: center.stopCommand
        case .skipForward: center.skipForwardCommand
        case .skipBackward: center.skipBackwardCommand
        case .changePlaybackPosition: center.changePlaybackPositionCommand
        case .nextTrack: center.nextTrackCommand
        case .previousTrack: center.previousTrackCommand
        }
    }

    private nonisolated static func makeHandler(
        for command: NowPlayingCommand,
        handler: @escaping @MainActor (NowPlayingCommandRequest) -> Bool
    ) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            let request = NowPlayingCommandRequest(command: command, position: position)
            guard Thread.isMainThread else {
                Task { @MainActor in
                    _ = handler(request)
                }
                return .success
            }
            let handled = MainActor.assumeIsolated { handler(request) }
            return handled ? .success : .commandFailed
        }
    }
}

final class BackendNowPlayingArtwork: NowPlayingArtworkProviding {
    func artwork(for media: NowPlayingMedia) async -> NSImage? {
        guard case let .audiobook(bookID) = media else { return NSApp.applicationIconImage }
        return await cover(for: bookID) ?? NSApp.applicationIconImage
    }

    private func cover(for bookID: String) async -> NSImage? {
        let path = "audiobook/\(bookID)/cover"
        if let cached = BackendImageCache.shared.object(forKey: path as NSString) {
            return cached
        }
        do {
            let request = try BackendConnection.shared.request(path: path, timeout: 10)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
                  let image = NSImage(data: data)
            else { return nil }
            BackendImageCache.shared.setObject(image, forKey: path as NSString)
            return image
        } catch {
            VoqoraLog.warn("NowPlaying", "Cover artwork unavailable", ["failureCode": "now_playing_artwork_failed"])
            return nil
        }
    }
}
