@testable import Voqora
import XCTest

@MainActor
final class NowPlayingStateTests: XCTestCase {
    func test_timelineSanitizesInvalidValues() {
        let timeline = NowPlayingTimeline(elapsed: 90, duration: 60, rate: .nan, isPlaying: true)
        XCTAssertEqual(timeline.elapsed, 60)
        XCTAssertEqual(timeline.rate, 1)

        let empty = NowPlayingTimeline(elapsed: -4, duration: .infinity, rate: 0, isPlaying: false)
        XCTAssertEqual(empty.duration, 0)
        XCTAssertEqual(empty.elapsed, 0)
        XCTAssertEqual(empty.rate, 1)
    }

    func test_expectedElapsedAdvancesAtThePlaybackRateOnlyWhilePlaying() {
        let playing = NowPlayingTimeline(elapsed: 10, duration: 30, rate: 1.5, isPlaying: true)
        XCTAssertEqual(playing.expectedElapsed(after: 4), 16, accuracy: 0.0001)
        XCTAssertEqual(playing.expectedElapsed(after: 100), 30, accuracy: 0.0001)

        let paused = NowPlayingTimeline(elapsed: 10, duration: 30, rate: 1.5, isPlaying: false)
        XCTAssertEqual(paused.expectedElapsed(after: 4), 10, accuracy: 0.0001)
    }

    func test_sectionReportsTheChapterAtTheCurrentTime() {
        let chapters = [
            section("Opening", at: 0),
            section("Chapter_One.pdf", at: 100),
            section("Chapter Two", at: 200),
        ]

        let section = NowPlayingSection.current(in: chapters, bookTitle: "Book", at: 150)

        XCTAssertEqual(section, NowPlayingSection(title: "Chapter One", index: 1, count: 3))
    }

    func test_sectionHidesATitleThatRepeatsTheBookAndNeedsMoreThanOneChapter() {
        let chapters = [section("book", at: 0), section("Chapter Two", at: 200)]

        XCTAssertNil(NowPlayingSection.current(in: chapters, bookTitle: "Book", at: 10)?.title)
        XCTAssertEqual(NowPlayingSection.current(in: chapters, bookTitle: "Book", at: 10)?.index, 0)
        XCTAssertNil(NowPlayingSection.current(in: [section("Only", at: 0)], bookTitle: "Book", at: 10))
    }

    func test_selectedTextStateUsesTheFixedTitleAndNavigatesBetweenSentences() {
        let timeline = NowPlayingTimeline(elapsed: 1, duration: 5, rate: 1, isPlaying: true)

        let single = NowPlayingState.selectedText(sentenceCount: 1, timeline: timeline)
        let several = NowPlayingState.selectedText(sentenceCount: 3, timeline: timeline)

        XCTAssertEqual(single.title, "Selected text")
        XCTAssertEqual(single.media, .selectedText)
        XCTAssertNil(single.section)
        XCTAssertFalse(single.canNavigateTracks)
        XCTAssertTrue(several.canNavigateTracks)
    }

    func test_refreshPolicyPublishesOnlyMeaningfulChanges() {
        let start = Date(timeIntervalSince1970: 0)
        let published = state(elapsed: 10, isPlaying: true)

        XCTAssertTrue(NowPlayingRefreshPolicy.needsRefresh(published: nil, publishedAt: nil, next: published, now: start))
        XCTAssertFalse(NowPlayingRefreshPolicy.needsRefresh(
            published: published,
            publishedAt: start,
            next: state(elapsed: 12.5, isPlaying: true),
            now: start.addingTimeInterval(2)
        ))
        XCTAssertTrue(NowPlayingRefreshPolicy.needsRefresh(
            published: published,
            publishedAt: start,
            next: state(elapsed: 30, isPlaying: true),
            now: start.addingTimeInterval(2)
        ))
        XCTAssertTrue(NowPlayingRefreshPolicy.needsRefresh(
            published: published,
            publishedAt: start,
            next: state(elapsed: 10, isPlaying: false),
            now: start
        ))
        XCTAssertTrue(NowPlayingRefreshPolicy.needsRefresh(
            published: published,
            publishedAt: start,
            next: state(elapsed: 10, isPlaying: true, duration: 80),
            now: start
        ))
    }

    func test_trackNavigationMovesToTheNextStart() {
        let starts: [TimeInterval] = [20, 0, 10]

        XCTAssertEqual(PlaybackTrackNavigation.nextStart(in: starts, after: 4), 10)
        XCTAssertEqual(PlaybackTrackNavigation.nextStart(in: starts, after: 9.8), 20)
        XCTAssertNil(PlaybackTrackNavigation.nextStart(in: starts, after: 20))
    }

    func test_trackNavigationRestartsTheCurrentTrackBeforeGoingBack() {
        let starts: [TimeInterval] = [0, 10, 20]

        XCTAssertEqual(PlaybackTrackNavigation.previousStart(in: starts, before: 15), 10)
        XCTAssertEqual(PlaybackTrackNavigation.previousStart(in: starts, before: 10.5), 0)
        XCTAssertEqual(PlaybackTrackNavigation.previousStart(in: starts, before: 0.5), 0)
        XCTAssertEqual(PlaybackTrackNavigation.previousStart(in: [], before: 7), 0)
    }

    func test_mediaKeysPreferenceDefaultsToOn() throws {
        let suiteName = "NowPlayingStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(NowPlayingPreferences.respondsToMediaKeys(defaults))

        defaults.set(false, forKey: NowPlayingPreferences.respondToMediaKeysKey)
        XCTAssertFalse(NowPlayingPreferences.respondsToMediaKeys(defaults))
    }

    func test_routeIsLostOnlyWhenThePreviousDeviceDisappears() {
        XCTAssertTrue(AudioOutputRoutePolicy.routeWasLost(previous: 7, current: 3, connected: [3]))
        XCTAssertFalse(AudioOutputRoutePolicy.routeWasLost(previous: 7, current: 3, connected: [3, 7]))
        XCTAssertFalse(AudioOutputRoutePolicy.routeWasLost(previous: 7, current: 7, connected: []))
        XCTAssertFalse(AudioOutputRoutePolicy.routeWasLost(previous: nil, current: 3, connected: [3]))
    }

    private func section(_ title: String, at time: TimeInterval) -> AudiobookSection {
        AudiobookSection(title: title, startPage: 1, endPage: 1, startTime: time)
    }

    private func state(elapsed: TimeInterval, isPlaying: Bool, duration: TimeInterval = 60) -> NowPlayingState {
        .selectedText(
            sentenceCount: 2,
            timeline: NowPlayingTimeline(elapsed: elapsed, duration: duration, rate: 1, isPlaying: isPlaying)
        )
    }
}
