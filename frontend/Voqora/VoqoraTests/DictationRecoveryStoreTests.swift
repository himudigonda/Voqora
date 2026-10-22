import Foundation
@testable import Voqora
import XCTest

@MainActor
final class DictationRecoveryStoreTests: XCTestCase {
    private var folder: URL!
    private var now: TimeInterval = 0

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        now = 100
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private var fileURL: URL {
        folder.appendingPathComponent("dictation-inflight.json")
    }

    private func makeStore() -> DictationRecoveryStore {
        DictationRecoveryStore(fileURL: fileURL, clock: { [weak self] in self?.now ?? 0 })
    }

    private func session(_ text: String) -> DictationInflightSession {
        DictationInflightSession(sessionID: 3, startedAt: Date(timeIntervalSince1970: 1_700_000_000), localeIdentifier: "en_US", text: text)
    }

    func test_recordWritesTheSessionAndPendingReadsItBack() {
        let store = makeStore()

        store.record(session("hello there"))

        XCTAssertEqual(store.pending(), session("hello there"))
    }

    func test_writesWithinHalfASecondAreThrottled() {
        let store = makeStore()
        store.record(session("one"))
        now += 0.3

        store.record(session("one two"))
        XCTAssertEqual(store.pending()?.text, "one")

        now += 0.3
        store.record(session("one two three"))
        XCTAssertEqual(store.pending()?.text, "one two three")
    }

    private func waitForPendingText(_ expected: String, in store: DictationRecoveryStore) async {
        for _ in 0 ..< 300 where store.pending()?.text != expected {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func test_aThrottledWriteIsFlushedLaterWithTheLatestSession() async {
        let store = makeStore()
        store.record(session("one"))
        now += 0.49

        store.record(session("one two"))
        store.record(session("one two three"))
        XCTAssertEqual(store.pending()?.text, "one")

        await waitForPendingText("one two three", in: store)
        XCTAssertEqual(store.pending()?.text, "one two three")
    }

    func test_clearCancelsTheTrailingWrite() async {
        let store = makeStore()
        store.record(session("one"))
        now += 0.49
        store.record(session("one two"))

        store.clear()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(store.pending())
    }

    func test_aForcedWriteSupersedesTheTrailingWrite() async {
        let store = makeStore()
        store.record(session("one"))
        now += 0.49
        store.record(session("one two"))

        store.record(session("final"), force: true)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(store.pending()?.text, "final")
    }

    func test_forcedWritesIgnoreTheThrottle() {
        let store = makeStore()
        store.record(session("one"))

        store.record(session("one two"), force: true)

        XCTAssertEqual(store.pending()?.text, "one two")
    }

    func test_clearDeletesTheFile() {
        let store = makeStore()
        store.record(session("one"))

        store.clear()

        XCTAssertNil(store.pending())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func test_clearResetsTheThrottle() {
        let store = makeStore()
        store.record(session("one"))
        store.clear()

        store.record(session("two"))

        XCTAssertEqual(store.pending()?.text, "two")
    }

    func test_anUnreadableFileIsIgnored() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)

        XCTAssertNil(makeStore().pending())
    }
}
