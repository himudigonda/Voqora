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
}
