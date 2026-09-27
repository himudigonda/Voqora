@testable import Voqora
import XCTest

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
