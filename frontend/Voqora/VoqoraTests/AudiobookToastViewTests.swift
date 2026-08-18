@testable import Voqora
import XCTest

/// Pure-logic test for `AudiobookToastView`'s per-kind line-limit
/// differentiation (jira-audiobook-quality.md T-18). Exercises the
/// `internal` static member added specifically so this logic is testable
/// without a live view, matching the `AudiobookPlayerLayoutTests` precedent.
final class AudiobookToastViewTests: XCTestCase {
    func test_lineLimit_errorIsUncapped() {
        XCTAssertNil(
            AudiobookToastView.lineLimit(for: .error),
            "error toasts often carry essential detail that a line cap would silently truncate"
        )
    }

    func test_lineLimit_infoAndSuccessStayTruncated() {
        XCTAssertEqual(AudiobookToastView.lineLimit(for: .info), 2)
        XCTAssertEqual(AudiobookToastView.lineLimit(for: .success), 2)
    }

    /// AudiobookViewModel.dismissDelayNanoseconds(for:) — the other half of
    /// T-18: an untruncated error message also needs longer on screen to be
    /// readable than the flat 4s every toast kind previously got.
    @MainActor
    func test_dismissDelay_errorGetsLongerWindowThanInfoAndSuccess() {
        let errorDelay = AudiobookViewModel.dismissDelayNanoseconds(for: .error)
        let infoDelay = AudiobookViewModel.dismissDelayNanoseconds(for: .info)
        let successDelay = AudiobookViewModel.dismissDelayNanoseconds(for: .success)

        XCTAssertGreaterThan(errorDelay, infoDelay)
        XCTAssertEqual(infoDelay, successDelay)
        XCTAssertEqual(infoDelay, 4_000_000_000)
    }
}
