@testable import Voqora
import XCTest

/// Tests for the v1.1 telemetry pipeline (S1-G6).
///
/// We test the static `Props.whitelist` boundary directly — that's where
/// the privacy guarantee lives. Higher-level concerns (HTTP batching,
/// outbox persistence) are covered by manual HAR captures listed in the
/// sprint verification section.
final class MetricsServiceTests: XCTestCase {
    // MARK: - Whitelist

    func test_whitelist_dropsUnknownKeys() {
        let raw: [String: Any] = [
            "chars": 42,
            "voice": "af_bella",
            "text": "leak me",
            "evil_payload": ["nested": "very bad"],
        ]
        let cleaned = MetricsService.Props.whitelist(raw)
        XCTAssertEqual(cleaned["chars"] as? Int, 42)
        XCTAssertEqual(cleaned["voice"] as? String, "af_bella")
        XCTAssertNil(cleaned["text"], "text MUST be dropped — this is the privacy guarantee")
        XCTAssertNil(cleaned["evil_payload"], "unknown keys MUST be dropped")
        XCTAssertEqual(cleaned.count, 2)
    }

    func test_whitelist_rejectsBadValues() {
        // Client validator is intentionally permissive on `voice` so a
        // server-added voice doesn't get dropped client-side. The server
        // re-validates against the enum (lib/voqora-validate.js). The
        // rest of these should drop client-side.
        let raw: [String: Any] = [
            "chars": -5, // negative — drop
            "speed": 3.0, // out of [0.5, 2.0] — drop
            "audio_seconds": "twelve", // wrong type — drop
            "file_kind": "exe", // not in pdf/txt/docx/md — drop
            "book_id_hash": "tooshort", // not 64 hex — drop
        ]
        let cleaned = MetricsService.Props.whitelist(raw)
        XCTAssertEqual(cleaned.count, 0, "All values fail client validation; output should be empty.")
    }

    func test_whitelist_acceptsValidValues() {
        let raw: [String: Any] = [
            "chars": 123,
            "voice": "am_adam",
            "speed": 1.5,
            "audio_seconds": 12.7,
            "pages": 30,
            "file_kind": "pdf",
            "book_id_hash": String(repeating: "a", count: 64),
        ]
        let cleaned = MetricsService.Props.whitelist(raw)
        XCTAssertEqual(cleaned.count, raw.count, "All valid values should survive.")
        XCTAssertEqual(cleaned["voice"] as? String, "am_adam")
    }

    // MARK: - Event names

    func test_eventNames_allowedSetIsClosed() {
        let known = MetricsService.Event.allowedNames
        XCTAssertEqual(known.count, 10)
        XCTAssertTrue(known.contains("generation"))
        XCTAssertTrue(known.contains("app_launch"))
        XCTAssertTrue(known.contains("audiobook_upload"))
        XCTAssertTrue(known.contains("installer_download_started"))
        XCTAssertTrue(known.contains("installer_download_verified"))
        XCTAssertTrue(known.contains("installer_opened"))
        XCTAssertTrue(known.contains("installer_failed"))
        XCTAssertFalse(known.contains("anything_else"))
    }

    func test_whitelist_acceptsEverySupportedDocumentKind() {
        for kind in ["pdf", "txt", "docx", "md"] {
            let cleaned = MetricsService.Props.whitelist(["file_kind": kind])
            XCTAssertEqual(cleaned["file_kind"] as? String, kind)
        }
        XCTAssertNil(MetricsService.Props.whitelist(["file_kind": "epub"])["file_kind"])
    }

    // MARK: - Outbox persistence

    func test_event_roundtrip_throughSerialization() {
        let evt = MetricsService.Event(
            name: "generation",
            props: ["chars": 10, "voice": "af_bella"],
            timestamp: Date()
        )
        let serialized = evt.serialized()
        let restored = MetricsService.Event.fromSerialized(serialized)
        XCTAssertEqual(restored?.name, "generation")
        XCTAssertEqual(restored?.props["chars"] as? Int, 10)
        XCTAssertEqual(restored?.props["voice"] as? String, "af_bella")
    }

    func test_event_fromSerialized_dropsUnknownEventName() {
        let payload: [String: Any] = ["event": "definitely_not_allowed", "props": [:]]
        XCTAssertNil(MetricsService.Event.fromSerialized(payload))
    }
}
