import Foundation
@testable import Voqora
import XCTest

final class LocalAPIModelTests: XCTestCase {
    func test_portParsing_acceptsOnlyTheAllowedRange() {
        XCTAssertEqual(LocalAPIPort.parse("51851"), 51851)
        XCTAssertEqual(LocalAPIPort.parse(" 1024 "), 1024)
        XCTAssertEqual(LocalAPIPort.parse("65535"), 65535)
        XCTAssertNil(LocalAPIPort.parse("1023"))
        XCTAssertNil(LocalAPIPort.parse("65536"))
        XCTAssertNil(LocalAPIPort.parse(""))
        XCTAssertNil(LocalAPIPort.parse("+8080"))
        XCTAssertNil(LocalAPIPort.parse("80 80"))
        XCTAssertNil(LocalAPIPort.parse("٨٠٨٠"))
        XCTAssertNil(LocalAPIPort.parse("99999999999999999999"))
        XCTAssertEqual(LocalAPIPort.defaultValue, 51851)
    }

    func test_keyEncoding_matchesTheBackendPattern() {
        let key = LocalAPIKey.encode([UInt8](repeating: 0xFB, count: LocalAPIKey.randomByteCount))

        XCTAssertTrue(key.hasPrefix("vq_"))
        XCTAssertFalse(key.contains("="))
        XCTAssertTrue(LocalAPIKey.isValid(key))
        XCTAssertEqual(key.count, 46)
    }

    func test_generatedKeysAreValidAndUnique() throws {
        let first = try XCTUnwrap(LocalAPIKey.generate())
        let second = try XCTUnwrap(LocalAPIKey.generate())

        XCTAssertTrue(LocalAPIKey.isValid(first))
        XCTAssertNotEqual(first, second)
    }

    func test_keyValidation_rejectsShortLongAndUnsafeKeys() {
        XCTAssertFalse(LocalAPIKey.isValid(String(repeating: "a", count: 31)))
        XCTAssertFalse(LocalAPIKey.isValid(String(repeating: "a", count: 129)))
        XCTAssertFalse(LocalAPIKey.isValid(String(repeating: "a", count: 31) + " "))
        XCTAssertFalse(LocalAPIKey.isValid(String(repeating: "é", count: 40)))
        XCTAssertTrue(LocalAPIKey.isValid(String(repeating: "a", count: 32)))
    }

    func test_maskedKeyHidesTheSecret() {
        let key = "vq_abcdefghijklmnopqrstuvwxyz0123456789ABCD"
        let masked = LocalAPIKey.masked(key)

        XCTAssertTrue(masked.hasPrefix("vq_"))
        XCTAssertTrue(masked.hasSuffix("ABCD"))
        XCTAssertFalse(masked.contains("abcdefgh"))
    }

    func test_configurationEncoding_usesBackendFieldNames() throws {
        let enabled = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalAPIConfiguration.enabled(port: 6000, apiKey: "k"))) as? [String: Any]
        XCTAssertEqual(enabled?["enabled"] as? Bool, true)
        XCTAssertEqual(enabled?["port"] as? Int, 6000)
        XCTAssertEqual(enabled?["api_key"] as? String, "k")

        let disabled = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalAPIConfiguration.disabled)) as? [String: Any]
        XCTAssertEqual(disabled?.keys.sorted(), ["enabled"])
        XCTAssertEqual(disabled?["enabled"] as? Bool, false)
    }

    func test_statusDecoding_readsErrorCodeAndOptionalPort() throws {
        let running = try JSONDecoder().decode(LocalAPIStatus.self, from: Data(#"{"enabled":true,"port":6000,"running":true}"#.utf8))
        XCTAssertEqual(running, LocalAPIStatus(enabled: true, port: 6000, running: true, errorCode: nil))

        let failed = try JSONDecoder().decode(
            LocalAPIStatus.self,
            from: Data(#"{"enabled":true,"port":6000,"running":false,"error":"busy","error_code":"port_in_use"}"#.utf8)
        )
        XCTAssertEqual(failed.failure, .portInUse)

        let never = try JSONDecoder().decode(LocalAPIStatus.self, from: Data(#"{"enabled":false,"running":false}"#.utf8))
        XCTAssertNil(never.port)
    }

    func test_phaseMapping_coversEveryState() {
        XCTAssertEqual(LocalAPIPhase(status: LocalAPIStatus(enabled: true, port: 6000, running: true, errorCode: nil), requestedPort: 1), .running(port: 6000))
        XCTAssertEqual(LocalAPIPhase(status: LocalAPIStatus(enabled: false, port: nil, running: false, errorCode: nil), requestedPort: 1), .off)
        XCTAssertEqual(
            LocalAPIPhase(status: LocalAPIStatus(enabled: true, port: nil, running: false, errorCode: "port_in_use"), requestedPort: 7000),
            .failed(LocalAPIFailure.portInUse.message(port: 7000))
        )
        XCTAssertEqual(
            LocalAPIPhase(status: LocalAPIStatus(enabled: true, port: 6000, running: false, errorCode: "mystery"), requestedPort: 6000),
            .failed(LocalAPIPhase.genericFailure)
        )
        XCTAssertEqual(
            LocalAPIPhase(status: LocalAPIStatus(enabled: true, port: 6000, running: false, errorCode: nil), requestedPort: 6000),
            .failed(LocalAPIPhase.genericFailure)
        )
    }

    func test_everyFailureCodeHasAMessageNamingThePort() {
        for failure in [LocalAPIFailure.portInUse, .permissionDenied, .bindFailed] {
            XCTAssertTrue(failure.message(port: 4321).contains("4321"), failure.rawValue)
        }
        XCTAssertEqual(LocalAPIFailure(rawValue: "start_timeout"), .startTimeout)
        XCTAssertEqual(LocalAPIFailure(rawValue: "stopped"), .stopped)
    }

    func test_snippetsIncludePortAndKey() {
        let curl = LocalAPISnippets.speechCurl(port: 6000, key: "KEY")
        XCTAssertTrue(curl.contains("http://127.0.0.1:6000/v1/audio/speech"))
        XCTAssertTrue(curl.contains("Authorization: Bearer KEY"))

        XCTAssertEqual(
            LocalAPISnippets.claudeCode(port: 6000, key: "KEY"),
            #"claude mcp add --transport http voqora http://127.0.0.1:6000/mcp --header "Authorization: Bearer KEY""#
        )

        let json = LocalAPISnippets.mcpServersJSON(port: 6000, key: "KEY")
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let server = (object?["mcpServers"] as? [String: Any])?["voqora"] as? [String: Any]
        XCTAssertEqual(server?["url"] as? String, "http://127.0.0.1:6000/mcp")
        XCTAssertEqual((server?["headers"] as? [String: String])?["Authorization"], "Bearer KEY")
    }
}

final class IntegrationEventParserTests: XCTestCase {
    func test_parsesReadySpeakAndStopFrames() {
        XCTAssertEqual(IntegrationEventParser.event(fromLine: #"data: {"type":"ready"}"#), .ready)
        XCTAssertEqual(
            IntegrationEventParser.event(fromLine: #"data: {"type":"speak","id":"a1","text":"Hello","voice":null}"#),
            .speak(RelaySpeakCommand(id: "a1", text: "Hello", voice: nil, client: nil))
        )
        XCTAssertEqual(
            IntegrationEventParser.event(fromLine: #"data: {"type":"speak","id":"a2","text":"Hi","voice":"bf_emma","client":"Claude Code"}"#),
            .speak(RelaySpeakCommand(id: "a2", text: "Hi", voice: "bf_emma", client: "Claude Code"))
        )
        XCTAssertEqual(IntegrationEventParser.event(fromLine: #"data: {"type":"stop","id":"s1"}"#), .stop(id: "s1"))
    }

    func test_ignoresCommentsMalformedAndIncompleteFrames() {
        XCTAssertNil(IntegrationEventParser.event(fromLine: ": keep-alive"))
        XCTAssertNil(IntegrationEventParser.event(fromLine: "data: not json"))
        XCTAssertNil(IntegrationEventParser.event(fromLine: #"data: {"type":"speak","id":"a1"}"#))
        XCTAssertNil(IntegrationEventParser.event(fromLine: #"data: {"type":"speak","id":"a1","text":"   "}"#))
        XCTAssertNil(IntegrationEventParser.event(fromLine: #"data: {"type":"stop"}"#))
        XCTAssertNil(IntegrationEventParser.event(fromLine: #"data: {"type":"other","id":"x"}"#))
    }

    func test_clientNamesAndVoicesAreLimitedInUnicodeScalars() {
        let combining = "e\u{301}"
        let name = IntegrationEventParser.clientName(String(repeating: combining, count: 100))
        XCTAssertEqual(name?.scalarCount, IntegrationEventParser.maximumClientNameLength)
        XCTAssertNotNil(IntegrationEventParser.voiceID(String(repeating: combining, count: 32)))
        XCTAssertNil(IntegrationEventParser.voiceID(String(repeating: combining, count: 33)))
    }

    func test_clientNamesAreCleanedAndLimited() {
        XCTAssertEqual(IntegrationEventParser.clientName("  Claude\n\tCode  "), "Claude Code")
        XCTAssertNil(IntegrationEventParser.clientName(" \u{0007} "))
        XCTAssertEqual(IntegrationEventParser.clientName(String(repeating: "x", count: 100))?.count, IntegrationEventParser.maximumClientNameLength)
    }

    func test_blankOrOversizedVoicesFallBackToTheSelectedVoice() {
        XCTAssertNil(IntegrationEventParser.voiceID("  "))
        XCTAssertNil(IntegrationEventParser.voiceID(String(repeating: "v", count: 65)))
        XCTAssertEqual(IntegrationEventParser.voiceID("af_heart"), "af_heart")
    }
}
