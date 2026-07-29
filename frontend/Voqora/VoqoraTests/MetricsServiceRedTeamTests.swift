@testable import Voqora
import XCTest

/// Red-team tests — adversarial payloads MUST be dropped before
/// `MetricsService` ever hands a request to URLSession.
///
/// This file is the **load-bearing** privacy test in the Swift app. If any
/// test in this file regresses, the public PRIVACY.md claim no longer
/// holds. Treat additions to this file as you would a security review:
/// every new event-shape or props key needs an adversarial case here.
///
/// The taxonomy of attacks we defend against:
///   1. Obvious leak keys: `text`, `email`, `prompt`, `content`, `body`.
///   2. Unicode lookalikes: `tеxt` (Cyrillic 'е'), zero-width characters.
///   3. Casing tricks: `Text`, `TEXT`, `tExt`.
///   4. Nested structures: dicts containing `text`, arrays of strings.
///   5. Encoded payloads: base64-blobbed prose under any key.
///   6. Reserved/internal keys that could overwrite metadata: `event`, `ts`,
///      `anon_id`, `app_version`, `platform`.
///   7. Out-of-spec value shapes for allowed keys (handled by Props validators).
///
/// We assert in two ways:
///   - Whitelist filter output contains only allowed keys.
///   - Byte-wise: serialized JSON of the cleaned event contains none of the
///     adversarial string values.
final class MetricsServiceRedTeamTests: XCTestCase {
    // MARK: - The adversarial taxonomy

    /// Strings we must never see in outbound JSON.
    private let secrets: [String] = [
        "This is the user's private text.",
        "user@example.com",
        "Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig",
        "SELECT * FROM users",
        "<script>alert(1)</script>",
        "../../etc/passwd",
        "OPENAI_API_KEY=sk-test",
    ]

    // MARK: - Obvious leak keys

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
        let cleaned = MetricsService.Props.whitelist(raw)
        XCTAssertEqual(cleaned.count, 0, "every adversarial key MUST be dropped")
    }

    // MARK: - Unicode lookalikes / casing tricks

    func test_redTeam_unicodeLookalikeKeysDropped() {
        // 'tеxt' uses Cyrillic 'е' (U+0435), not Latin 'e' (U+0065). A naive
        // string filter would let this through; the closed whitelist must not.
        let raw: [String: Any] = [
            "tеxt": secrets[0], // Cyrillic
            "te\u{200B}xt": secrets[0], // zero-width space
            "𝐭𝐞𝐱𝐭": secrets[0], // mathematical bold
        ]
        let cleaned = MetricsService.Props.whitelist(raw)
        XCTAssertEqual(cleaned.count, 0)
    }

    func test_redTeam_casingVariantsOfTextKeyDropped() {
        let raw: [String: Any] = [
            "Text": secrets[0],
            "TEXT": secrets[0],
            "tExt": secrets[0],
            "tEXT": secrets[0],
        ]
        let cleaned = MetricsService.Props.whitelist(raw)
        XCTAssertEqual(cleaned.count, 0, "the whitelist is case-sensitive — only 'voice' (lower) lets a string through")
    }

    // MARK: - Nested structures hiding leaks

    func test_redTeam_nestedDictUnderUnknownKeyDropped() {
        let raw: [String: Any] = [
            "metadata": [
                "user_text": secrets[0],
                "email": secrets[1],
            ],
        ]
        let cleaned = MetricsService.Props.whitelist(raw)
        XCTAssertNil(cleaned["metadata"])
    }

    func test_redTeam_nestedArrayOfStringsUnderUnknownKeyDropped() {
        let raw: [String: Any] = [
            "selection_history": secrets,
        ]
        let cleaned = MetricsService.Props.whitelist(raw)
        XCTAssertEqual(cleaned.count, 0)
    }

    // MARK: - Encoded / disguised payloads

    func test_redTeam_base64BlobUnderUnknownKeyDropped() {
        let blob = Data(secrets[0].utf8).base64EncodedString()
        let raw: [String: Any] = [
            "diagnostic_blob": blob,
            "telemetry_payload": blob,
        ]
        let cleaned = MetricsService.Props.whitelist(raw)
        XCTAssertEqual(cleaned.count, 0)
    }

    // MARK: - Server-reserved keys must not be hijacked through props

    func test_redTeam_reservedTopLevelKeysIgnoredInProps() {
        // Even if an attacker tries to overwrite the outbox's top-level
        // shape via props, those keys aren't in the whitelist, so they drop.
        let raw: [String: Any] = [
            "event": "definitely_not_allowed",
            "ts": "1970-01-01T00:00:00Z",
            "anon_id": "ATTACKER_CONTROLLED",
            "app_version": "9.9.9-evil",
            "platform": "ROOTKIT",
        ]
        let cleaned = MetricsService.Props.whitelist(raw)
        XCTAssertEqual(cleaned.count, 0)
    }

    // MARK: - Out-of-spec values for allowed keys

    func test_redTeam_allowedKeysWithAdversarialValues() {
        let raw: [String: Any] = [
            "chars": "drop table users", // wrong type → drop
            "speed": Double.infinity, // out of [0.5,2.0] → drop
            "audio_seconds": -1.0, // negative → drop
            "pages": "9999999999", // wrong type → drop
            "file_kind": "exe", // not in {pdf,txt,epub} → drop
            "book_id_hash": "G".paddedToFiftyFour(), // non-hex → drop
            "seconds_played": Double.nan, // NaN handling
        ]
        let cleaned = MetricsService.Props.whitelist(raw)
        XCTAssertNil(cleaned["chars"])
        XCTAssertNil(cleaned["speed"])
        XCTAssertNil(cleaned["audio_seconds"])
        XCTAssertNil(cleaned["pages"])
        XCTAssertNil(cleaned["file_kind"])
        XCTAssertNil(cleaned["book_id_hash"])
        // NaN: validators check `>= 0` which is false for NaN → drop
        XCTAssertNil(cleaned["seconds_played"])
    }

    // MARK: - Byte-wise: serialized JSON contains no leaked content

    func test_redTeam_serializedEventBytesContainNoAdversarialContent() throws {
        let raw: [String: Any] = [
            "chars": 10,
            "voice": "af_bella",
            // All of these MUST be filtered before serialization.
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
            props: MetricsService.Props.whitelist(raw),
            timestamp: Date(timeIntervalSince1970: 0)
        )
        let serialized = evt.serialized()
        let data = try JSONSerialization.data(withJSONObject: serialized)
        guard let bytes = String(data: data, encoding: .utf8) else {
            XCTFail("could not decode serialized event bytes")
            return
        }

        // The output should contain the allowed keys.
        XCTAssertTrue(bytes.contains("\"voice\""))
        XCTAssertTrue(bytes.contains("\"chars\""))

        // The output MUST NOT contain any of the adversarial values.
        for secret in secrets {
            XCTAssertFalse(
                bytes.contains(secret),
                "serialized event leaked adversarial content: \(secret)"
            )
        }

        // Nor the adversarial keys.
        for badKey in ["text", "email", "prompt", "metadata", "user_selection", "Text", "tеxt"] {
            XCTAssertFalse(
                bytes.contains("\"\(badKey)\":"),
                "serialized event contained adversarial key: \(badKey)"
            )
        }
    }

    // MARK: - Event name closed-set

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

    // MARK: - Empty + nil tolerance

    func test_redTeam_emptyPropsProducesEmptyDict() {
        let cleaned = MetricsService.Props.whitelist([:])
        XCTAssertEqual(cleaned.count, 0)
    }

    func test_redTeam_nilValueDropsKey() {
        let raw: [String: Any] = ["chars": NSNull()]
        let cleaned = MetricsService.Props.whitelist(raw)
        XCTAssertNil(cleaned["chars"])
    }
}

private extension String {
    /// 64-char string starting with the receiver, padded with 'X' (non-hex).
    func paddedToFiftyFour() -> String {
        let pad = String(repeating: "X", count: 64 - count)
        return self + pad
    }
}
