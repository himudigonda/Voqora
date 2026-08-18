@testable import Voqora
import XCTest

/// Pure-logic tests for `AudiobookPlayerView`'s memoized transcript/section
/// lookup (jira-audiobook-quality.md T-12). These exercise the `internal`
/// static members added specifically so this logic is testable without a
/// live view/window — see the `AudiobookPlayerLayoutTests`/
/// `AudiobookViewModel.libraryPollInterval` precedent this file follows.
final class AudiobookPlayerViewTests: XCTestCase {
    // MARK: - sortPages / sortPageTimes / sortSections

    func test_sortPages_sortsAscendingByPageNumberAndDropsNonIntegerKeys() {
        let pages = ["3": "third", "1": "first", "2": "second", "not-a-number": "junk"]
        let sorted = AudiobookPlayerView.sortPages(pages)
        XCTAssertEqual(
            sorted,
            [
                AudiobookPlayerView.PageEntry(page: 1, text: "first"),
                AudiobookPlayerView.PageEntry(page: 2, text: "second"),
                AudiobookPlayerView.PageEntry(page: 3, text: "third"),
            ]
        )
    }

    func test_sortPageTimes_sortsAscendingByTime() {
        let pageToTime = ["5": 40.0, "1": 0.0, "3": 20.0]
        let sorted = AudiobookPlayerView.sortPageTimes(pageToTime)
        XCTAssertEqual(
            sorted,
            [
                AudiobookPlayerView.PageTimeEntry(page: 1, time: 0.0),
                AudiobookPlayerView.PageTimeEntry(page: 3, time: 20.0),
                AudiobookPlayerView.PageTimeEntry(page: 5, time: 40.0),
            ]
        )
    }

    func test_sortSections_sortsAscendingByStartTime() {
        let sections = [
            makeSection(title: "C", startPage: 21, endPage: 30, startTime: 200),
            makeSection(title: "A", startPage: 1, endPage: 10, startTime: 0),
            makeSection(title: "B", startPage: 11, endPage: 20, startTime: 100),
        ]
        let sorted = AudiobookPlayerView.sortSections(sections)
        XCTAssertEqual(sorted.map(\.title), ["A", "B", "C"])
    }

    // MARK: - currentPageID / currentSection match the old unmemoized
    // (compactMap + sort + `last(where:)`) implementation across a range of
    // `currentTime` values, including exact boundaries.

    func test_currentPageID_matchesReferenceImplementationAcrossTimeRangeIncludingBoundaries() {
        let pageToTime = ["1": 0.0, "2": 10.0, "3": 25.0, "4": 25.0, "5": 60.0]
        let sortedTimes = AudiobookPlayerView.sortPageTimes(pageToTime)

        // -1 (before start), each exact boundary, values strictly between
        // boundaries, and past the last page's start time.
        let sampleTimes: [Double] = [-1, 0, 5, 10, 24.999, 25, 25.001, 59, 60, 1_000]
        for time in sampleTimes {
            let expected = referenceCurrentPageID(pageToTime: pageToTime, at: time)
            let actual = AudiobookPlayerView.currentPageID(in: sortedTimes, at: time)
            XCTAssertEqual(actual, expected, "mismatch at t=\(time)")
        }
    }

    func test_currentPageID_emptyTranscriptReturnsNil() {
        XCTAssertNil(AudiobookPlayerView.currentPageID(in: [], at: 100))
    }

    func test_currentSection_matchesReferenceImplementationAcrossTimeRangeIncludingBoundaries() {
        let sections = [
            makeSection(title: "Intro", startPage: 1, endPage: 5, startTime: 0),
            makeSection(title: "Middle", startPage: 6, endPage: 20, startTime: 120),
            makeSection(title: "End", startPage: 21, endPage: 30, startTime: 300),
        ]
        let sortedSections = AudiobookPlayerView.sortSections(sections)

        let sampleTimes: [Double] = [-1, 0, 60, 119.999, 120, 120.001, 299, 300, 300.001, 10_000]
        for time in sampleTimes {
            let expected = referenceCurrentSection(sections: sections, at: time)
            let actual = AudiobookPlayerView.currentSection(in: sortedSections, at: time)
            XCTAssertEqual(actual, expected, "mismatch at t=\(time)")
        }
    }

    func test_currentSection_noSectionsReturnsNil() {
        XCTAssertNil(AudiobookPlayerView.currentSection(in: [], at: 100))
    }

    // MARK: - Helpers

    /// The pre-T-12 implementation, kept only here as a reference oracle.
    private func referenceCurrentPageID(pageToTime: [String: Double], at now: Double) -> Int? {
        pageToTime
            .compactMap { (key, time) -> (Int, Double)? in Int(key).map { ($0, time) } }
            .sorted { $0.1 < $1.1 }
            .last(where: { $0.1 <= now })?.0
    }

    /// The pre-T-12 implementation of `AudiobookViewModel.currentSection(in:)`,
    /// kept only here as a reference oracle.
    private func referenceCurrentSection(sections: [AudiobookSection], at now: Double) -> AudiobookSection? {
        sections
            .sorted { $0.startTime < $1.startTime }
            .last(where: { $0.startTime <= now })
    }

    private func makeSection(title: String, startPage: Int, endPage: Int, startTime: Double) -> AudiobookSection {
        AudiobookSection(title: title, startPage: startPage, endPage: endPage, startTime: startTime)
    }
}
