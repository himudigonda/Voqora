@testable import Voqora
import XCTest

/// Covers the pasteboard save/restore helpers backing the Cmd+C clipboard
/// fallback in SelectionManager. Runs against a scratch NSPasteboard (never
/// NSPasteboard.general) so it can't disturb the real system clipboard.
@MainActor
final class SelectionManagerTests: XCTestCase {
    func test_snapshotAndRestore_roundTripsOriginalContent() {
        let pasteboard = NSPasteboard(name: .init("com.himudigonda.Voqora.SelectionManagerTests"))
        pasteboard.clearContents()
        pasteboard.setString("original clipboard contents", forType: .string)

        let snapshot = SelectionManager.snapshotPasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("text copied by the Cmd+C fallback", forType: .string)
        XCTAssertEqual(pasteboard.string(forType: .string), "text copied by the Cmd+C fallback")

        SelectionManager.restorePasteboard(snapshot, pasteboard: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "original clipboard contents")
    }

    func test_snapshotAndRestore_emptyPasteboardStaysEmpty() {
        let pasteboard = NSPasteboard(name: .init("com.himudigonda.Voqora.SelectionManagerTests.empty"))
        pasteboard.clearContents()

        let snapshot = SelectionManager.snapshotPasteboard(pasteboard)
        XCTAssertTrue(snapshot.isEmpty)

        pasteboard.setString("text copied by the Cmd+C fallback", forType: .string)
        SelectionManager.restorePasteboard(snapshot, pasteboard: pasteboard)

        XCTAssertNil(pasteboard.string(forType: .string))
    }
}
