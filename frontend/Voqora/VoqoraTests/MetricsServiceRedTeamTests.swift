@testable import Voqora
import XCTest

final class MetricsServiceRedTeamTests: XCTestCase {
    private let secrets: [String] = [
        "This is the user's private text.",
        "user@example.com",
        "Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig",
        "SELECT * FROM users",
        "<script>alert(1)</script>",
        "../../etc/passwd",
        "OPENAI_API_KEY=sk-test",
    ]

    func test_redTeam_obviousLeakKeysAllDropped() {
        let raw: [String: Any] = [
            "text": secrets[0],
            "email": secrets[1],
            "prompt": secrets[0],
            "content": secrets[0],
            "body": secrets[0],
            "message": secrets[0],
            "user_text": secrets[0],
            "input": secrets[0],
            "transcript": secrets[0],
            "selection": secrets[0],
            "highlighted": secrets[0],
        ]
        let cleaned = MetricsService.Props.sanitizedPayload(raw)
        XCTAssertEqual(cleaned.count, 0, "every adversarial key MUST be dropped")
    }

    func test_redTeam_unicodeLookalikeKeysDropped() {
        let raw: [String: Any] = [
            "tеxt": secrets[0], // Cyrillic
            "te\u{200B}xt": secrets[0], // zero-width space
            "𝐭𝐞𝐱𝐭": secrets[0], // mathematical bold
        ]
        let cleaned = MetricsService.Props.sanitizedPayload(raw)
        XCTAssertEqual(cleaned.count, 0)
    }

    func test_redTeam_casingVariantsOfTextKeyDropped() {
        let raw: [String: Any] = [
            "Text": secrets[0],
            "TEXT": secrets[0],
            "tExt": secrets[0],
            "tEXT": secrets[0],
        ]
        let cleaned = MetricsService.Props.sanitizedPayload(raw)
        XCTAssertEqual(cleaned.count, 0, "the allowlist is case-sensitive — only 'voice' (lower) lets a string through")
    }

    func test_redTeam_nestedDictUnderUnknownKeyDropped() {
        let raw: [String: Any] = [
            "metadata": [
                "user_text": secrets[0],
                "email": secrets[1],
            ],
        ]
        let cleaned = MetricsService.Props.sanitizedPayload(raw)
        XCTAssertNil(cleaned["metadata"])
    }

    func test_redTeam_nestedArrayOfStringsUnderUnknownKeyDropped() {
        let raw: [String: Any] = [
            "selection_history": secrets,
        ]
        let cleaned = MetricsService.Props.sanitizedPayload(raw)
        XCTAssertEqual(cleaned.count, 0)
    }

    func test_redTeam_base64BlobUnderUnknownKeyDropped() {
        let blob = Data(secrets[0].utf8).base64EncodedString()
        let raw: [String: Any] = [
            "diagnostic_blob": blob,
            "telemetry_payload": blob,
        ]
        let cleaned = MetricsService.Props.sanitizedPayload(raw)
        XCTAssertEqual(cleaned.count, 0)
    }

    func test_redTeam_reservedTopLevelKeysIgnoredInProps() {
        let raw: [String: Any] = [
            "event": "definitely_not_allowed",
            "ts": "1970-01-01T00:00:00Z",
            "anon_id": "ATTACKER_CONTROLLED",
            "app_version": "9.9.9-evil",
            "platform": "ROOTKIT",
        ]
        let cleaned = MetricsService.Props.sanitizedPayload(raw)
        XCTAssertEqual(cleaned.count, 0)
    }

    func test_redTeam_allowedKeysWithAdversarialValues() {
        let raw: [String: Any] = [
            "chars": "drop table users", // wrong type → drop
            "speed": Double.infinity, // out of [0.5,2.0] → drop
            "audio_seconds": -1.0, // negative → drop
            "pages": "9999999999", // wrong type → drop
            "file_kind": "exe", // not an accepted document kind → drop
            "book_id_hash": "G".paddedToFiftyFour(), // non-hex → drop
            "seconds_played": Double.nan, // NaN handling
        ]
        let cleaned = MetricsService.Props.sanitizedPayload(raw)
        XCTAssertNil(cleaned["chars"])
        XCTAssertNil(cleaned["speed"])
        XCTAssertNil(cleaned["audio_seconds"])
        XCTAssertNil(cleaned["pages"])
        XCTAssertNil(cleaned["file_kind"])
        XCTAssertNil(cleaned["book_id_hash"])
        XCTAssertNil(cleaned["seconds_played"])
    }

    func test_redTeam_serializedEventBytesContainNoAdversarialContent() throws {
        let raw: [String: Any] = [
            "chars": 10,
            "voice": "af_bella",
            "text": secrets[0],
            "email": secrets[1],
            "prompt": secrets[2],
            "metadata": ["nested_text": secrets[0]],
            "user_selection": secrets[3],
            "Text": secrets[0],
            "tеxt": secrets[0], // Cyrillic
        ]
        let evt = MetricsService.Event(
            name: "generation",
            props: MetricsService.Props.sanitizedPayload(raw),
            timestamp: Date(timeIntervalSince1970: 0)
        )
        let serialized = evt.serialized()
        let data = try JSONSerialization.data(withJSONObject: serialized)
        guard let bytes = String(data: data, encoding: .utf8) else {
            XCTFail("could not decode serialized event bytes")
            return
        }

        XCTAssertTrue(bytes.contains("\"voice\""))
        XCTAssertTrue(bytes.contains("\"chars\""))

        for secret in secrets {
            XCTAssertFalse(
                bytes.contains(secret),
                "serialized event leaked adversarial content: \(secret)"
            )
        }

        for badKey in ["text", "email", "prompt", "metadata", "user_selection", "Text", "tеxt"] {
            XCTAssertFalse(
                bytes.contains("\"\(badKey)\":"),
                "serialized event contained adversarial key: \(badKey)"
            )
        }
    }

    func test_redTeam_unknownEventNamesAreRejectedFromOutbox() {
        let attacker: [String: Any] = [
            "event": "leak_all_text",
            "props": ["text": secrets[0]],
        ]
        XCTAssertNil(MetricsService.Event.fromSerialized(attacker))
    }

    func test_redTeam_eventFromSerializedAlsoWhitelistsProps() {
        let allowedName = "generation"
        let payload: [String: Any] = [
            "event": allowedName,
            "ts": "2026-05-26T00:00:00.000Z",
            "props": [
                "chars": 5,
                "text": secrets[0], // must be stripped on restore
                "email": secrets[1],
            ],
        ]
        let restored = MetricsService.Event.fromSerialized(payload)
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.props["chars"] as? Int, 5)
        XCTAssertNil(restored?.props["text"])
        XCTAssertNil(restored?.props["email"])
    }

    func test_redTeam_emptyPropsProducesEmptyDict() {
        let cleaned = MetricsService.Props.sanitizedPayload([:])
        XCTAssertEqual(cleaned.count, 0)
    }

    func test_redTeam_nilValueDropsKey() {
        let raw: [String: Any] = ["chars": NSNull()]
        let cleaned = MetricsService.Props.sanitizedPayload(raw)
        XCTAssertNil(cleaned["chars"])
    }
}

private extension String {
    func paddedToFiftyFour() -> String {
        let pad = String(repeating: "X", count: 64 - count)
        return self + pad
    }
}
