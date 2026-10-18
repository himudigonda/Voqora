import Foundation

nonisolated enum NowPlayingMedia: Equatable, Sendable {
    case selectedText
    case audiobook(bookID: String)
}

nonisolated enum NowPlayingCommand: Hashable, CaseIterable, Sendable {
    case play
    case pause
    case togglePlayPause
    case stop
    case skipForward
    case skipBackward
    case changePlaybackPosition
    case nextTrack
    case previousTrack
}

nonisolated struct NowPlayingCommandRequest: Equatable, Sendable {
    let command: NowPlayingCommand
    let position: TimeInterval?

    init(command: NowPlayingCommand, position: TimeInterval? = nil) {
        self.command = command
        self.position = position
    }
}

nonisolated struct NowPlayingTimeline: Equatable, Sendable {
    let elapsed: TimeInterval
    let duration: TimeInterval
    let rate: Double
    let isPlaying: Bool

    init(elapsed: TimeInterval, duration: TimeInterval, rate: Double, isPlaying: Bool) {
        let safeDuration = duration.isFinite ? max(0, duration) : 0
        self.duration = safeDuration
        self.elapsed = elapsed.isFinite ? min(max(0, elapsed), safeDuration) : 0
        self.rate = rate.isFinite && rate > 0 ? rate : 1
        self.isPlaying = isPlaying
    }

    func expectedElapsed(after interval: TimeInterval) -> TimeInterval {
        isPlaying ? min(duration, elapsed + max(0, interval) * rate) : elapsed
    }
}

nonisolated struct NowPlayingSection: Equatable, Sendable {
    let title: String?
    let index: Int
    let count: Int

    static func current(in chapters: [AudiobookSection], bookTitle: String, at time: TimeInterval) -> NowPlayingSection? {
        guard chapters.count > 1, let index = chapters.lastIndex(where: { $0.startTime <= time }) else { return nil }
        let name = AudiobookImportStaging.displayName(from: chapters[index].title)
        let repeatsBookTitle = name.caseInsensitiveCompare(bookTitle) == .orderedSame
        return NowPlayingSection(title: name.isEmpty || repeatsBookTitle ? nil : name, index: index, count: chapters.count)
    }
}

nonisolated struct NowPlayingState: Equatable, Sendable {
    static let selectedTextTitle = "Selected text"
    static let artist = "Voqora"

    let media: NowPlayingMedia
    let title: String
    let section: NowPlayingSection?
    let canNavigateTracks: Bool
    let timeline: NowPlayingTimeline

    static func selectedText(sentenceCount: Int, timeline: NowPlayingTimeline) -> NowPlayingState {
        NowPlayingState(
            media: .selectedText,
            title: selectedTextTitle,
            section: nil,
            canNavigateTracks: sentenceCount > 1,
            timeline: timeline
        )
    }

    static func audiobook(bookID: String, title: String, chapters: [AudiobookSection], timeline: NowPlayingTimeline) -> NowPlayingState {
        NowPlayingState(
            media: .audiobook(bookID: bookID),
            title: title,
            section: NowPlayingSection.current(in: chapters, bookTitle: title, at: timeline.elapsed),
            canNavigateTracks: chapters.count > 1,
            timeline: timeline
        )
    }

    func sharesMetadata(with other: NowPlayingState) -> Bool {
        media == other.media
            && title == other.title
            && section == other.section
            && canNavigateTracks == other.canNavigateTracks
            && timeline.rate == other.timeline.rate
            && timeline.isPlaying == other.timeline.isPlaying
    }
}

nonisolated enum NowPlayingRefreshPolicy {
    static let timelineTolerance: TimeInterval = 1

    static func needsRefresh(published: NowPlayingState?, publishedAt: Date?, next: NowPlayingState, now: Date) -> Bool {
        guard let published, let publishedAt, published.sharesMetadata(with: next) else { return true }
        if abs(published.timeline.duration - next.timeline.duration) > timelineTolerance {
            return true
        }
        let expected = published.timeline.expectedElapsed(after: now.timeIntervalSince(publishedAt))
        return abs(expected - next.timeline.elapsed) > timelineTolerance
    }
}

nonisolated enum PlaybackTrackNavigation {
    static let restartThreshold: TimeInterval = 3

    static func nextStart(in starts: [TimeInterval], after time: TimeInterval) -> TimeInterval? {
        starts.sorted().first { $0 > time + 0.5 }
    }

    static func previousStart(in starts: [TimeInterval], before time: TimeInterval) -> TimeInterval {
        let sorted = starts.sorted()
        if let current = sorted.last(where: { $0 <= time }), time - current > restartThreshold {
            return current
        }
        return sorted.last { $0 < time - 1 } ?? 0
    }
}

nonisolated enum NowPlayingPreferences {
    static let respondToMediaKeysKey = "respondToMediaKeys"

    static func respondsToMediaKeys(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: respondToMediaKeysKey) as? Bool ?? true
    }
}
