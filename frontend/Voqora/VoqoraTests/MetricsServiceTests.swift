@testable import Voqora
import XCTest

final class MetricsServiceTests: XCTestCase {
    func test_sanitizedPayload_dropsUnknownKeys() {
        let raw: [String: Any] = [
            "chars": 42,
            "voice": "af_bella",
            "text": "leak me",
            "evil_payload": ["nested": "very bad"],
        ]
        let cleaned = MetricsService.Props.sanitizedPayload(raw)
        XCTAssertEqual(cleaned["chars"] as? Int, 42)
        XCTAssertEqual(cleaned["voice"] as? String, "af_bella")
        XCTAssertNil(cleaned["text"], "text MUST be dropped — this is the privacy guarantee")
        XCTAssertNil(cleaned["evil_payload"], "unknown keys MUST be dropped")
        XCTAssertEqual(cleaned.count, 2)
    }

    func test_sanitizedPayload_rejectsBadValues() {
        let raw: [String: Any] = [
            "chars": -5, // negative — drop
            "speed": 3.0, // out of [0.5, 2.0] — drop
            "audio_seconds": "twelve", // wrong type — drop
            "file_kind": "exe", // not an accepted document kind — drop
            "book_id_hash": "tooshort", // not 64 hex — drop
        ]
        let cleaned = MetricsService.Props.sanitizedPayload(raw)
        XCTAssertEqual(cleaned.count, 0, "All values fail client validation; output should be empty.")
    }

    func test_sanitizedPayload_acceptsValidValues() {
        let raw: [String: Any] = [
            "chars": 123,
            "voice": "am_adam",
            "speed": 1.5,
            "audio_seconds": 12.7,
            "pages": 30,
            "file_kind": "pdf",
            "book_id_hash": String(repeating: "a", count: 64),
        ]
        let cleaned = MetricsService.Props.sanitizedPayload(raw)
        XCTAssertEqual(cleaned.count, raw.count, "All valid values should survive.")
        XCTAssertEqual(cleaned["voice"] as? String, "am_adam")
    }

    func test_sanitizedPayload_preservesEverySupportedAudiobookDocumentKind() {
        for fileKind in ["pdf", "txt", "docx", "md"] {
            let cleaned = MetricsService.Props.sanitizedPayload(["file_kind": fileKind])
            XCTAssertEqual(cleaned["file_kind"] as? String, fileKind)
        }
    }

    func test_eventNames_allowedSetIsClosed() {
        let known = MetricsService.Event.allowedNames
        XCTAssertEqual(known.count, 20)
        XCTAssertTrue(known.contains("generation"))
        XCTAssertTrue(known.contains("app_launch"))
        XCTAssertTrue(known.contains("audiobook_upload"))
        XCTAssertTrue(known.contains("installer_download_started"))
        XCTAssertTrue(known.contains("installer_download_verified"))
        XCTAssertTrue(known.contains("installer_opened"))
        XCTAssertTrue(known.contains("installer_failed"))
        XCTAssertFalse(known.contains("anything_else"))
    }

    func test_event_roundtrip_throughSerialization() {
        let evt = MetricsService.Event(
            name: "generation",
            props: ["chars": 10, "voice": "af_bella"],
            timestamp: Date()
        )
        let serialized = evt.serialized()
        let restored = MetricsService.Event.fromSerialized(serialized)
        XCTAssertEqual(restored?.id, evt.id)
        XCTAssertEqual(restored?.name, "generation")
        XCTAssertEqual(restored?.props["chars"] as? Int, 10)
        XCTAssertEqual(restored?.props["voice"] as? String, "af_bella")
    }

    func test_legacyOutboxEventGetsStableIDWhenRestored() {
        let payload: [String: Any] = ["event": "app_launch", "props": [:]]
        let restored = MetricsService.Event.fromSerialized(payload)
        XCTAssertNotNil(UUID(uuidString: restored?.id ?? ""))
        XCTAssertNotNil(restored?.serialized()["event_id"] as? String)
    }

    func test_event_fromSerialized_dropsUnknownEventName() {
        let payload: [String: Any] = ["event": "definitely_not_allowed", "props": [:]]
        XCTAssertNil(MetricsService.Event.fromSerialized(payload))
    }

    func test_analyticsDefaultsOffAndHonorsOptIn() throws {
        let suiteName = "MetricsServiceTests.analytics.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(MetricsService.userAllowsAnalytics(defaults))
        defaults.set(true, forKey: MetricsService.analyticsEnabledKey)
        XCTAssertTrue(MetricsService.userAllowsAnalytics(defaults))
        defaults.set(false, forKey: MetricsService.analyticsEnabledKey)
        XCTAssertFalse(MetricsService.userAllowsAnalytics(defaults))
    }

    func test_flushBackoffGrowsAndCaps() {
        XCTAssertEqual(MetricsService.backoffSeconds(afterFailures: 0), 0)
        XCTAssertEqual(MetricsService.backoffSeconds(afterFailures: 1), 30)
        XCTAssertEqual(MetricsService.backoffSeconds(afterFailures: 2), 60)
        XCTAssertEqual(MetricsService.backoffSeconds(afterFailures: 50), 30 * 60)
    }

    func test_onlyNonRetryableClientErrorsDropABatch() {
        XCTAssertTrue(MetricsService.isPermanentRejection(400))
        XCTAssertTrue(MetricsService.isPermanentRejection(422))
        XCTAssertFalse(MetricsService.isPermanentRejection(429))
        XCTAssertFalse(MetricsService.isPermanentRejection(408))
        XCTAssertFalse(MetricsService.isPermanentRejection(503))
        XCTAssertFalse(MetricsService.isPermanentRejection(200))
    }

    func test_everyContractEventNameIsAllowed() {
        let contract = [
            "app_launch", "generation", "export", "audiobook_upload", "audiobook_play", "gemini_clean",
            "installer_download_started", "installer_download_verified", "installer_opened", "installer_failed",
            "speech_failed", "dictation", "audiobook_generated", "audiobook_finished", "podcast_script",
            "podcast_render", "ai_request", "relay_request", "library_import", "daily_usage",
        ]
        XCTAssertEqual(MetricsService.Event.allowedNames, Set(contract))
    }

    func test_generationAcceptsTheExtendedProps() {
        let cleaned = MetricsService.Props.sanitizedPayload([
            "chars": 10, "voice": "af_bella", "speed": 1.0, "audio_seconds": 3.5,
            "engine": "kokoro", "source": "selection", "first_audio_ms": 320, "render_ms": 2100, "words": 2,
        ])
        XCTAssertEqual(cleaned.count, 9)
        XCTAssertEqual(cleaned["engine"] as? String, "kokoro")
        XCTAssertEqual(cleaned["source"] as? String, "selection")
        XCTAssertEqual(cleaned["first_audio_ms"] as? Int, 320)
        XCTAssertEqual(cleaned["render_ms"] as? Int, 2100)
        XCTAssertEqual(cleaned["words"] as? Int, 2)
    }

    func test_speechFailedProps() {
        let cleaned = MetricsService.Props.sanitizedPayload(["engine": "ming", "source": "relay", "failure_code": "rejected_503"])
        XCTAssertEqual(cleaned.count, 3)
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["failure_code": "Has Spaces"])["failure_code"])
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["failure_code": ""])["failure_code"])
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["failure_code": String(repeating: "a", count: 49)])["failure_code"])
        XCTAssertNotNil(MetricsService.Props.sanitizedPayload(["failure_code": String(repeating: "a", count: 48)])["failure_code"])
    }

    func test_dictationProps() {
        let cleaned = MetricsService.Props.sanitizedPayload([
            "words": 12, "audio_seconds": 8.25, "outcome": "copied_app_changed", "language": "en", "tidied": true,
        ])
        XCTAssertEqual(cleaned.count, 5)
        XCTAssertEqual(cleaned["tidied"] as? Bool, true)
        for outcome in ["pasted", "copied", "copied_needs_accessibility", "copied_app_changed", "cancelled", "empty"] {
            XCTAssertEqual(MetricsService.Props.sanitizedPayload(["outcome": outcome])["outcome"] as? String, outcome)
        }
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["outcome": "imported"])["outcome"])
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["tidied": 1])["tidied"])
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["words": true])["words"])
    }

    func test_audiobookProps() {
        let cleaned = MetricsService.Props.sanitizedPayload([
            "chapters": 24, "audio_seconds": 7200.0, "render_seconds": 900, "engine": "supertonic",
        ])
        XCTAssertEqual(cleaned.count, 4)
        XCTAssertEqual(cleaned["render_seconds"] as? Double, 900)
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["chapters": 10001])["chapters"])
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["render_seconds": -1.0])["render_seconds"])
        XCTAssertTrue(MetricsService.Props.sanitizedPayload([:]).isEmpty)
    }

    func test_podcastProps() {
        let cleaned = MetricsService.Props.sanitizedPayload(["speakers": 2, "provider": "gemini", "ok": false, "audio_seconds": 100.0])
        XCTAssertEqual(cleaned.count, 4)
        XCTAssertEqual(cleaned["ok"] as? Bool, false)
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["speakers": 0])["speakers"])
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["speakers": 9])["speakers"])
        XCTAssertNotNil(MetricsService.Props.sanitizedPayload(["speakers": 8])["speakers"])
    }

    func test_aiRequestProps() {
        for tool in ["summarize", "translate", "ask", "quiz", "flashcards", "tidy", "podcast_script"] {
            XCTAssertEqual(MetricsService.Props.sanitizedPayload(["tool": tool])["tool"] as? String, tool)
        }
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["tool": "dictate"])["tool"])
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["latency_ms": 600_001])["latency_ms"])
        XCTAssertEqual(MetricsService.Props.sanitizedPayload(["latency_ms": 600_000])["latency_ms"] as? Int, 600_000)
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["latency_ms": -1])["latency_ms"])
        for provider in MetricsService.Bucket.providers {
            XCTAssertEqual(MetricsService.Props.sanitizedPayload(["provider": provider])["provider"] as? String, provider)
        }
    }

    func test_relayAndImportProps() {
        for client in ["claude", "cursor", "codex", "chatgpt", "raycast", "vscode", "windsurf", "zed", "cli", "other"] {
            XCTAssertEqual(MetricsService.Props.sanitizedPayload(["client": client])["client"] as? String, client)
        }
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["client": "Claude Desktop"])["client"])
        for kind in ["pdf", "epub", "txt", "docx", "md", "html", "web", "inbox", "text", "other"] {
            XCTAssertEqual(MetricsService.Props.sanitizedPayload(["kind": kind])["kind"] as? String, kind)
        }
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["kind": "exe"])["kind"])
    }

    func test_dailyUsagePropsFromALedgerDay() {
        var usage = DayUsage()
        usage.speechCount = 4
        usage.speechSeconds = 120.5
        usage.listeningSeconds = 600
        usage.dictation.words = 80
        usage.dictation.seconds = 59.5
        usage.ai.requests = ["ask": 2, "quiz": 1]
        let props = MetricsService.dailyUsageProps(day: "2026-10-19", usage: usage)
        let cleaned = MetricsService.Props.sanitizedPayload(props)
        XCTAssertEqual(cleaned.count, 8)
        XCTAssertEqual(cleaned["day"] as? String, "2026-10-19")
        XCTAssertEqual(cleaned["listen_seconds"] as? Double, 600)
        XCTAssertEqual(cleaned["speech_count"] as? Int, 4)
        XCTAssertEqual(cleaned["speech_seconds"] as? Double, 120.5)
        XCTAssertEqual(cleaned["dictation_words"] as? Int, 80)
        XCTAssertEqual(cleaned["dictation_seconds"] as? Double, 59.5)
        XCTAssertEqual(cleaned["ai_requests"] as? Int, 3)
        XCTAssertEqual(cleaned["active_minutes"] as? Int, 13)
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["day": "2026-10-19T00:00"])["day"])
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["day": "yesterday"])["day"])
    }

    func test_voiceValidatorFollowsTheContractRegex() {
        XCTAssertNotNil(MetricsService.Props.sanitizedPayload(["voice": "ming:custom"])["voice"])
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["voice": "supertonic:F1"])["voice"])
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["voice": "My Own Voice"])["voice"])
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["voice": String(repeating: "a", count: 65)])["voice"])
        XCTAssertNil(MetricsService.Props.sanitizedPayload(["voice": "af_bella\n"])["voice"])
    }

    func test_numbersSurviveAJSONRoundTripOfTheOutbox() throws {
        let props = MetricsService.Props.sanitizedPayload(["ok": true, "words": 3, "render_seconds": 2.5, "tidied": false])
        let event = MetricsService.Event(name: "dictation", props: props, timestamp: Date())
        let data = try JSONSerialization.data(withJSONObject: event.serialized())
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let restored = try XCTUnwrap(MetricsService.Event.fromSerialized(raw))
        XCTAssertEqual(restored.props["ok"] as? Bool, true)
        XCTAssertEqual(restored.props["tidied"] as? Bool, false)
        XCTAssertEqual(restored.props["words"] as? Int, 3)
        XCTAssertEqual(restored.props["render_seconds"] as? Double, 2.5)
    }

    func test_engineBuckets() {
        XCTAssertEqual(MetricsService.Bucket.engine("kokoro"), "kokoro")
        XCTAssertEqual(MetricsService.Bucket.engine("Ming"), "ming")
        XCTAssertEqual(MetricsService.Bucket.engine("supertonic"), "supertonic")
        XCTAssertEqual(MetricsService.Bucket.engine("blend"), "blend")
        XCTAssertEqual(MetricsService.Bucket.engine("blend:\(UUID().uuidString.lowercased())"), "blend")
        XCTAssertEqual(MetricsService.Bucket.engine("gpt-voice-9"), "other")
        XCTAssertEqual(MetricsService.Bucket.voice("blend:\(UUID().uuidString.lowercased())"), "blend")
        XCTAssertEqual(MetricsService.Bucket.voice("ming:custom:Grandma"), "ming:custom")
        XCTAssertEqual(MetricsService.Bucket.voice("af_bella"), "af_bella")
        XCTAssertEqual(MetricsService.Bucket.voice("ming:US_James"), "ming:us_james")
        XCTAssertEqual(MetricsService.Bucket.voice("supertonic:F1"), "supertonic:f1")
    }

    func test_providerBuckets() {
        XCTAssertEqual(MetricsService.Bucket.provider("google"), "gemini")
        XCTAssertEqual(MetricsService.Bucket.provider("OpenAI"), "openai")
        XCTAssertEqual(MetricsService.Bucket.provider("cerebras"), "other")
        XCTAssertEqual(MetricsService.Bucket.provider("http://my.server:11434"), "other")
        for provider in LLMProvider.allCases {
            XCTAssertTrue(MetricsService.Bucket.providers.contains(MetricsService.Bucket.provider(provider.rawValue)))
        }
    }

    func test_clientBucketsNeverEchoTheRawName() {
        XCTAssertEqual(MetricsService.Bucket.client("Claude Desktop"), "claude")
        XCTAssertEqual(MetricsService.Bucket.client("claude-code"), "claude")
        XCTAssertEqual(MetricsService.Bucket.client("Cursor"), "cursor")
        XCTAssertEqual(MetricsService.Bucket.client("Codex CLI"), "codex")
        XCTAssertEqual(MetricsService.Bucket.client("ChatGPT"), "chatgpt")
        XCTAssertEqual(MetricsService.Bucket.client("Raycast"), "raycast")
        XCTAssertEqual(MetricsService.Bucket.client("Visual Studio Code"), "vscode")
        XCTAssertEqual(MetricsService.Bucket.client("Windsurf"), "windsurf")
        XCTAssertEqual(MetricsService.Bucket.client("Zed"), "zed")
        XCTAssertEqual(MetricsService.Bucket.client("curl/8.4"), "cli")
        XCTAssertEqual(MetricsService.Bucket.client("alice@example.com"), "other")
        XCTAssertEqual(MetricsService.Bucket.client("Alice's Notes Plugin"), "other")
        XCTAssertEqual(MetricsService.Bucket.client("Xcode"), "other")
        XCTAssertEqual(MetricsService.Bucket.client(nil), "other")
        XCTAssertEqual(MetricsService.Bucket.client(""), "other")
    }

    func test_languageBuckets() {
        XCTAssertEqual(MetricsService.Bucket.language("en_US"), "en")
        XCTAssertEqual(MetricsService.Bucket.language("zh-Hans-CN"), "zh")
        XCTAssertEqual(MetricsService.Bucket.language("fil"), "fil")
        XCTAssertEqual(MetricsService.Bucket.language("EN"), "en")
        XCTAssertNil(MetricsService.Bucket.language("e"))
        XCTAssertNil(MetricsService.Bucket.language("english"))
        XCTAssertNil(MetricsService.Bucket.language(nil))
        XCTAssertNil(MetricsService.Bucket.language(""))
        XCTAssertNil(MetricsService.Bucket.language("12"))
    }

    func test_failureCodeBucketsAreAlwaysContractShaped() {
        XCTAssertEqual(MetricsService.Bucket.failureCode("Rejected 503!"), "rejected_503_")
        XCTAssertEqual(MetricsService.Bucket.failureCode(""), "unknown")
        XCTAssertEqual(MetricsService.Bucket.failureCode(String(repeating: "z", count: 100)).count, 48)
        for raw in ["Voqora can't read /Users/me/secret.txt", "héllo wörld", "UPPER"] {
            let code = MetricsService.Bucket.failureCode(raw)
            XCTAssertNotNil(MetricsService.Props.sanitizedPayload(["failure_code": code])["failure_code"], raw)
        }
    }

    func test_speechFailureCodesFromErrors() {
        XCTAssertEqual(MetricsService.Bucket.speechFailureCode(for: BackendService.StreamError.emptyAudio), "empty_audio")
        XCTAssertEqual(MetricsService.Bucket.speechFailureCode(for: BackendService.StreamError.rejectedResponse(statusCode: 422)), "rejected_422")
        XCTAssertEqual(MetricsService.Bucket.speechFailureCode(for: URLError(.timedOut)), "network_error")
        XCTAssertEqual(MetricsService.Bucket.speechFailureCode(for: CocoaError(.fileNoSuchFile)), "engine_unreachable")
    }

    func test_importKindBuckets() {
        XCTAssertEqual(MetricsService.Bucket.importKind("PDF"), "pdf")
        XCTAssertEqual(MetricsService.Bucket.importKind(".epub"), "epub")
        XCTAssertEqual(MetricsService.Bucket.importKind("htm"), "html")
        XCTAssertEqual(MetricsService.Bucket.importKind("markdown"), "md")
        XCTAssertEqual(MetricsService.Bucket.importKind("url"), "other")
        XCTAssertEqual(MetricsService.Bucket.importKind("secret-report.pdf"), "other")
    }

    func test_transportRefusesNonHTTPSEndpoints() throws {
        let secure = try XCTUnwrap(URL(string: "https://himudigonda.me/api/voqora/events"))
        let plain = try XCTUnwrap(URL(string: "http://himudigonda.me/api/voqora/events"))
        let ftp = try XCTUnwrap(URL(string: "ftp://himudigonda.me/x"))
        let hostless = try XCTUnwrap(URL(string: "https:///nohost"))
        XCTAssertTrue(MetricsService.isSecureEndpoint(secure))
        XCTAssertFalse(MetricsService.isSecureEndpoint(plain))
        XCTAssertFalse(MetricsService.isSecureEndpoint(ftp))
        XCTAssertFalse(MetricsService.isSecureEndpoint(hostless))
    }

    func test_dedicatedSessionIsEphemeralAndHardened() {
        let configuration = MetricsService.makeSecureSession().configuration
        XCTAssertEqual(configuration.tlsMinimumSupportedProtocolVersion, .TLSv12)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertFalse(MetricsService.session === URLSession.shared)
    }

    func test_batchBodyShrinksBelowTheCap() throws {
        let events = (0 ..< 20).map { _ in
            MetricsService.Event(name: "generation", props: ["chars": 5], timestamp: Date())
        }
        let full = try XCTUnwrap(MetricsService.boundedBody(events: events, anonID: "a", appVersion: "1"))
        XCTAssertEqual(full.count, 20)

        let single = try XCTUnwrap(MetricsService.boundedBody(events: [events[0]], anonID: "a", appVersion: "1"))
        let capped = try XCTUnwrap(MetricsService.boundedBody(events: events, anonID: "a", appVersion: "1", maxBytes: single.body.count * 5))
        XCTAssertLessThan(capped.count, 20)
        XCTAssertGreaterThanOrEqual(capped.count, 1)
        XCTAssertLessThanOrEqual(capped.body.count, single.body.count * 5)
        XCTAssertNil(MetricsService.boundedBody(events: events, anonID: "a", appVersion: "1", maxBytes: 10))
        XCTAssertEqual(MetricsService.maxBatchBytes, 64 * 1024)
    }

    func test_dailyUsageSendsOncePerDayForYesterdayOnlyWhenOptedIn() throws {
        let suiteName = "MetricsServiceTests.daily.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9)))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        var ledger = UsageLedger()
        ledger.recordSpeech(SpeechSample(text: "a b", voice: "af_bella", speed: 1, audioSeconds: 5), at: yesterday, calendar: calendar)
        var sent: [(String, DayUsage)] = []

        MainActor.assumeIsolated {
            MetricsService.sendDailyUsageIfDue(now: now, defaults: defaults, ledger: ledger, calendar: calendar) { sent.append(($0, $1)) }
        }
        XCTAssertTrue(sent.isEmpty, "opted out: nothing sent")
        XCTAssertEqual(defaults.string(forKey: MetricsService.lastDailyUsageKey), "2026-10-19")

        defaults.set(true, forKey: MetricsService.analyticsEnabledKey)
        defaults.removeObject(forKey: MetricsService.lastDailyUsageKey)
        MainActor.assumeIsolated {
            MetricsService.sendDailyUsageIfDue(now: now, defaults: defaults, ledger: ledger, calendar: calendar) { sent.append(($0, $1)) }
            MetricsService.sendDailyUsageIfDue(now: now.addingTimeInterval(3600), defaults: defaults, ledger: ledger, calendar: calendar) { sent.append(($0, $1)) }
        }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.0, "2026-10-19")
        XCTAssertEqual(sent.first?.1.speechCount, 1)

        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: now))
        MainActor.assumeIsolated {
            MetricsService.sendDailyUsageIfDue(now: nextDay, defaults: defaults, ledger: ledger, calendar: calendar) { sent.append(($0, $1)) }
        }
        XCTAssertEqual(sent.count, 1, "a day with no activity sends nothing")
        XCTAssertEqual(defaults.string(forKey: MetricsService.lastDailyUsageKey), "2026-10-20")
    }
}
