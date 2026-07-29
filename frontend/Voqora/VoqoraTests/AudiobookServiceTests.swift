@testable import Voqora
import XCTest

/// Transcript-decoding tests (the v1.1 design notes Sprint 2, T2.1).
///
/// The backend's transcript.json gained two new, additive top-level keys
/// ("segments", "dropped_segments") in Sprint 1 — see
/// backend/app/services/audiobook_service.py's _phase_concat. Both MUST be
/// optional on the Swift side: a non-optional stored property would make
/// JSONDecoder throw DecodingError.keyNotFound on every transcript.json
/// written before this shipped. These tests decode both an old-shape fixture
/// (mirroring real pre-Sprint-1 transcript.json files found on disk at
/// ~/Library/Application Support/com.himudigonda.Voqora/audiobooks/*/transcript.json)
/// and a new-shape fixture, proving the old one does not throw.
final class AudiobookServiceTests: XCTestCase {
    private let decoder = JSONDecoder()

    // MARK: - Fixtures

    /// Exact key set confirmed against a real, on-disk, pre-Sprint-1
    /// transcript.json: {book_id, sections, page_to_time, total_audio_seconds,
    /// pages} — no "segments"/"dropped_segments" keys at all.
    private let oldShapeJSON = """
    {
        "book_id": "abc123",
        "sections": [
            {"title": "Chapter One", "start_page": 1, "end_page": 3, "start_time": 0.0}
        ],
        "page_to_time": {"1": 0.0, "2": 12.5},
        "total_audio_seconds": 25.0,
        "pages": {"1": "First page text.", "2": "Second page text."}
    }
    """

    /// Sprint 1 shape: additive "segments"/"dropped_segments" keys, per
    /// the v1.1 design notes §6.5. Note "1" has real segments, "2" is entirely absent from
    /// "segments" (no sidecar for that page) — both are valid per §6.5.
    private let newShapeJSON = """
    {
        "book_id": "abc123",
        "sections": [
            {"title": "Chapter One", "start_page": 1, "end_page": 3, "start_time": 0.0}
        ],
        "page_to_time": {"1": 0.0, "2": 12.5},
        "total_audio_seconds": 25.0,
        "pages": {"1": "First page text.", "2": "Second page text."},
        "segments": {
            "1": [
                {"text": "First page text.", "start_sec": 0.0, "end_sec": 1.2}
            ]
        },
        "dropped_segments": {
            "2": [
                {"index": 3, "text": "a segment that failed to synthesize"}
            ]
        }
    }
    """

    // MARK: - T2.1: old-shape decode must not throw

    func test_oldShapeTranscript_decodesWithoutThrowing() throws {
        let data = Data(oldShapeJSON.utf8)
        let transcript = try decoder.decode(AudiobookService.Transcript.self, from: data)
        XCTAssertEqual(transcript.bookID, "abc123")
        XCTAssertEqual(transcript.pages.count, 2)
    }

    func test_oldShapeTranscript_segmentsAndDroppedSegmentsAreNil() throws {
        let data = Data(oldShapeJSON.utf8)
        let transcript = try decoder.decode(AudiobookService.Transcript.self, from: data)
        XCTAssertNil(transcript.segments, "old transcript.json has no \"segments\" key — must decode to nil, not throw")
        XCTAssertNil(transcript.droppedSegments, "old transcript.json has no \"dropped_segments\" key — must decode to nil, not throw")
    }

    // MARK: - T2.1: new-shape decode

    func test_newShapeTranscript_decodesSegments() throws {
        let data = Data(newShapeJSON.utf8)
        let transcript = try decoder.decode(AudiobookService.Transcript.self, from: data)
        let page1 = try XCTUnwrap(transcript.segments?["1"])
        XCTAssertEqual(page1.count, 1)
        XCTAssertEqual(page1[0].text, "First page text.")
        XCTAssertEqual(page1[0].startSec, 0.0)
        XCTAssertEqual(page1[0].endSec, 1.2)
    }

    func test_newShapeTranscript_pageAbsentFromSegmentsIsNotAnError() throws {
        let data = Data(newShapeJSON.utf8)
        let transcript = try decoder.decode(AudiobookService.Transcript.self, from: data)
        // Page "2" has no sidecar — absent from the dict entirely, not a
        // zero-length placeholder (the v1.1 design notes §6.5).
        XCTAssertNil(transcript.segments?["2"])
    }

    func test_newShapeTranscript_decodesDroppedSegments() throws {
        let data = Data(newShapeJSON.utf8)
        let transcript = try decoder.decode(AudiobookService.Transcript.self, from: data)
        let dropped = try XCTUnwrap(transcript.droppedSegments?["2"])
        XCTAssertEqual(dropped.count, 1)
        XCTAssertEqual(dropped[0].index, 3)
        XCTAssertEqual(dropped[0].text, "a segment that failed to synthesize")
    }

    // MARK: - Round-trip

    func test_transcriptSegment_roundTripsThroughEncodeDecode() throws {
        let original = AudiobookService.TranscriptSegment(text: "hello", startSec: 1.0, endSec: 2.5)
        let data = try JSONEncoder().encode(original)
        let decoded = try decoder.decode(AudiobookService.TranscriptSegment.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - the v1.1 design notes Sprint 7, T7.4/E4: stale local-cache invalidation
    //
    // `ensureLocalAudio` only ever checks existence of the cached
    // `<bookID>.wav`, never freshness, so a successful server-side "retry
    // failed pages" was masked forever by the stale, still-broken cached
    // copy. `retry(_:apiKey:)` now calls `removeLocalCache(for:)` on success,
    // mirroring `delete(_:)`. `AudiobookService` makes real `URLSession`
    // calls with no protocol seam to substitute, so exercising the live
    // network-success branch of `retry` itself isn't reliable in a unit test
    // (same limitation documented on `AudiobookViewModel.applyStatus`) — this
    // instead directly proves the shared cache-invalidation primitive both
    // `delete(_:)` and `retry(_:apiKey:)` call.

    func test_removeLocalCache_deletesExistingCachedFile() throws {
        let service = AudiobookService()
        let id = "test-cache-\(UUID().uuidString)"
        let url = service.localCachedAudioURL(for: id)
        try Data("fake wav bytes".utf8).write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        service.removeLocalCache(for: id)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "E4: a successful retry must invalidate the stale cached audio so the next play() re-fetches instead of replaying the still-broken copy"
        )
    }

    func test_removeLocalCache_isSafeWhenNoCacheExists() {
        let service = AudiobookService()
        // Must not throw/crash when there's nothing to delete (e.g. retry
        // succeeding for a book that was never played locally).
        service.removeLocalCache(for: "no-such-book-\(UUID().uuidString)")
    }

    // MARK: - the v1.1 design notes Sprint 7, T7.11/E12: cancel() surfaces failures

    /// Whether or not a real backend happens to be reachable at
    /// 127.0.0.1:10101, a fabricated book id can never return 2xx: a real
    /// backend has no record of it (404) and no backend at all fails to
    /// connect. Either way `cancel(_:)` must throw rather than silently
    /// no-op, so this is deterministic regardless of environment.
    func test_cancel_throwsForNonexistentBook() async {
        let service = AudiobookService()
        do {
            try await service.cancel("definitely-not-a-real-book-\(UUID().uuidString)")
            XCTFail("E12: cancel() must throw on a non-2xx response or network failure, not silently no-op")
        } catch {
            // Expected.
        }
    }

    // MARK: - the v1.1 design notes Sprint 7, T7.10/E11: stalled reconnect state

    /// Points at a guaranteed-closed port (127.0.0.1:1 is reserved/unlisted
    /// on macOS) so every connection attempt fails fast and deterministically
    /// — independent of whether a real backend happens to be running on the
    /// app's actual port. After `stalledReconnectThreshold` consecutive
    /// failures, `subscribe(to:)` must yield a synthetic `"stalled"` event
    /// instead of only logging via `print()`.
    func test_subscribe_yieldsStalledEventAfterConsecutiveFailures() async {
        let service = AudiobookService(baseURL: URL(string: "http://127.0.0.1:1")!)
        let stream = service.subscribe(to: "any-book")

        let sawStalled = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in stream {
                    if event["type"] as? String == "stalled" {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                // Threshold failures back off 1s + 2s (~3s) before the 3rd
                // failure crosses the threshold; this is a generous margin.
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        XCTAssertTrue(sawStalled, "E11: N consecutive SSE reconnect failures must surface a stalled/reconnecting event")
    }
}
