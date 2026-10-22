import Foundation
import SwiftUI

actor MetricsService {
    static let shared = MetricsService()

    private let endpoint = URL(string: "https://himudigonda.me/api/voqora/events")!
    private let outboxKey = "metrics_outbox_v2"
    private let outboxCap = 200
    private let flushBatchSize = 20
    nonisolated static let flushIntervalSeconds: TimeInterval = 30
    nonisolated static let analyticsEnabledKey = "analyticsEnabled"
    nonisolated static let lastDailyUsageKey = "metrics_daily_usage_last_day"

    private var userID: String?
    private var enabled: Bool
    private var outbox: [Event] = []
    private var isFlushing = false
    private var consecutiveFailures = 0
    private var nextFlushAllowed = Date.distantPast

    nonisolated static func userAllowsAnalytics(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: analyticsEnabledKey) as? Bool ?? false
    }

    private var isActive: Bool {
        enabled && Self.userAllowsAnalytics()
    }

    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        userID = UserDefaults.standard.string(forKey: "anonymousUserID")
        enabled = true
        outbox = Self.loadOutbox()
    }

    func eraseLocalData() {
        enabled = false
        userID = nil
        outbox.removeAll()
        UserDefaults.standard.removeObject(forKey: outboxKey)
        UserDefaults.standard.removeObject(forKey: "anonymousUserID")
        UserDefaults.standard.removeObject(forKey: Self.lastDailyUsageKey)
    }

    nonisolated func trackLaunch() {
        Task { await self.enqueue(event: "app_launch", props: [:], flushImmediately: true) }
    }

    nonisolated func trackGeneration(
        chars: Int,
        voice: String,
        speed: Double,
        audioSeconds: Double,
        engine: String? = nil,
        source: String? = nil,
        firstAudioMs: Int? = nil,
        renderMs: Int? = nil,
        words: Int? = nil
    ) {
        var props: [String: Any] = [
            "chars": chars,
            "voice": Self.Bucket.voice(voice),
            "speed": speed,
            "audio_seconds": audioSeconds,
        ]
        if let engine {
            props["engine"] = Self.Bucket.engine(engine)
        }
        if let source {
            props["source"] = source
        }
        if let firstAudioMs {
            props["first_audio_ms"] = firstAudioMs
        }
        if let renderMs {
            props["render_ms"] = renderMs
        }
        if let words {
            props["words"] = words
        }
        Task { await self.enqueue(event: "generation", props: props) }
    }

    nonisolated func trackSpeechFailed(engine: String, source: String, failureCode: String) {
        track("speech_failed", [
            "engine": Self.Bucket.engine(engine),
            "source": source,
            "failure_code": Self.Bucket.failureCode(failureCode),
        ])
    }

    nonisolated func trackDictation(words: Int, audioSeconds: Double?, outcome: String, language: String?, tidied: Bool) {
        var props: [String: Any] = ["words": words, "outcome": outcome, "tidied": tidied]
        if let audioSeconds {
            props["audio_seconds"] = audioSeconds
        }
        if let language = Self.Bucket.language(language) {
            props["language"] = language
        }
        track("dictation", props)
    }

    nonisolated func trackAudiobookGenerated(chapters: Int, audioSeconds: Double, renderSeconds: Double, engine: String) {
        track("audiobook_generated", [
            "chapters": chapters,
            "audio_seconds": audioSeconds,
            "render_seconds": renderSeconds,
            "engine": Self.Bucket.engine(engine),
        ])
    }

    nonisolated func trackAudiobookFinished() {
        track("audiobook_finished", [:])
    }

    nonisolated func trackPodcastScript(speakers: Int, provider: String, ok: Bool) {
        track("podcast_script", ["speakers": speakers, "provider": Self.Bucket.provider(provider), "ok": ok])
    }

    nonisolated func trackPodcastRender(speakers: Int, audioSeconds: Double?, ok: Bool) {
        var props: [String: Any] = ["speakers": speakers, "ok": ok]
        if let audioSeconds {
            props["audio_seconds"] = audioSeconds
        }
        track("podcast_render", props)
    }

    nonisolated func trackAIRequest(tool: String, provider: String, ok: Bool, latencyMs: Int) {
        track("ai_request", [
            "tool": tool,
            "provider": Self.Bucket.provider(provider),
            "ok": ok,
            "latency_ms": latencyMs,
        ])
    }

    nonisolated func trackRelayRequest(client: String?) {
        track("relay_request", ["client": Self.Bucket.client(client)])
    }

    nonisolated func trackLibraryImport(kind: String) {
        track("library_import", ["kind": Self.Bucket.importKind(kind)])
    }

    nonisolated func trackDailyUsage(day: String, usage: DayUsage) {
        track("daily_usage", Self.dailyUsageProps(day: day, usage: usage))
    }

    private nonisolated func track(_ event: String, _ props: [String: Any]) {
        Task { await self.enqueue(event: event, props: props) }
    }

    nonisolated static func dailyUsageProps(day: String, usage: DayUsage) -> [String: Any] {
        [
            "day": day,
            "listen_seconds": usage.listeningSeconds,
            "speech_count": usage.speechCount,
            "speech_seconds": usage.speechSeconds,
            "dictation_words": usage.dictation.words,
            "dictation_seconds": usage.dictation.seconds,
            "ai_requests": usage.ai.totalRequests,
            "active_minutes": Int((usage.activeSeconds / 60).rounded()),
        ]
    }

    nonisolated func trackExport(audioSeconds: Double) {
        Task { await self.enqueue(event: "export", props: ["audio_seconds": audioSeconds]) }
    }

    nonisolated func trackAudiobookUpload(pages: Int, fileKind: String) {
        Task {
            await self.enqueue(event: "audiobook_upload",
                               props: ["pages": pages, "file_kind": fileKind])
        }
    }

    nonisolated func trackAudiobookPlay(bookIDHash: String, secondsPlayed: Double) {
        Task {
            await self.enqueue(event: "audiobook_play", props: [
                "book_id_hash": bookIDHash,
                "seconds_played": secondsPlayed,
            ])
        }
    }

    nonisolated func trackInstallerDownloadStarted() {
        Task { await self.enqueue(event: "installer_download_started", props: [:]) }
    }

    nonisolated func trackInstallerDownloadVerified() {
        Task { await self.enqueue(event: "installer_download_verified", props: [:]) }
    }

    nonisolated func trackInstallerOpened() {
        Task { await self.enqueue(event: "installer_opened", props: [:]) }
    }

    nonisolated func trackInstallerFailed() {
        Task { await self.enqueue(event: "installer_failed", props: [:]) }
    }

    nonisolated func flush() {
        Task { await self.flushLocked() }
    }

    private func enqueue(
        event: String,
        props rawProps: [String: Any],
        flushImmediately: Bool = false
    ) async {
        guard isActive else { return }
        guard Event.allowedNames.contains(event) else {
            await MainActor.run {
                VoqoraLog.warn("MetricsService", "Unknown event dropped", ["event": event])
            }
            return
        }
        let cleanedProps = Props.sanitizedPayload(rawProps)
        let evt = Event(name: event, props: cleanedProps, timestamp: Date())
        outbox.append(evt)
        if outbox.count > outboxCap {
            outbox.removeFirst(outbox.count - outboxCap)
        }
        persistOutbox()
        if flushImmediately || outbox.count >= flushBatchSize {
            await flushLocked()
        }
    }

    private func flushLocked() async {
        guard isActive else {
            outbox.removeAll()
            persistOutbox()
            return
        }
        guard !isFlushing, !outbox.isEmpty, Date() >= nextFlushAllowed else { return }
        guard Self.isSecureEndpoint(endpoint) else {
            await MainActor.run {
                VoqoraLog.error("MetricsService", "Insecure endpoint refused", ["failureCode": "telemetry_endpoint_insecure"])
            }
            return
        }
        isFlushing = true
        defer { isFlushing = false }
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        guard let built = Self.boundedBody(
            events: Array(outbox.prefix(flushBatchSize)),
            anonID: anonymousID(),
            appVersion: appVersion
        ) else {
            outbox.removeFirst()
            persistOutbox()
            await MainActor.run {
                VoqoraLog.error("MetricsService", "Oversized event dropped", ["failureCode": "telemetry_event_oversized"])
            }
            return
        }
        let body = built.body
        let batch = Array(outbox.prefix(built.count))

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (_, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if Self.isPermanentRejection(http.statusCode) {
                outbox.removeFirst(min(batch.count, outbox.count))
                persistOutbox()
                recordFailure()
                await MainActor.run {
                    VoqoraLog.warn("MetricsService", "Server rejected batch, dropping it", ["statusCode": "\(http.statusCode)", "batchSize": "\(batch.count)"])
                }
                return
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                recordFailure()
                await MainActor.run {
                    VoqoraLog.warn("MetricsService", "Server unavailable, retaining batch", ["statusCode": "\(http.statusCode)", "batchSize": "\(batch.count)"])
                }
                return
            }
            consecutiveFailures = 0
            nextFlushAllowed = .distantPast
            outbox.removeFirst(min(batch.count, outbox.count))
            persistOutbox()
            await MainActor.run {
                VoqoraLog.debug("MetricsService", "Flushed batch", ["events": "\(batch.count)", "statusCode": "\(http.statusCode)"])
            }
        } catch {
            recordFailure()
            await MainActor.run {
                VoqoraLog.error("MetricsService", "Flush failed", ["failureCode": "telemetry_flush_failed"])
            }
        }
    }

    nonisolated static let maxBatchBytes = 64 * 1024

    nonisolated static let session: URLSession = makeSecureSession()

    nonisolated static func makeSecureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    nonisolated static func isSecureEndpoint(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
    }

    nonisolated static func boundedBody(
        events: [Event],
        anonID: String,
        appVersion: String,
        maxBytes: Int = maxBatchBytes
    ) -> (body: Data, count: Int)? {
        var count = events.count
        while count > 0 {
            let payload: [String: Any] = [
                "anon_id": anonID,
                "product": "voqora",
                "app_version": appVersion,
                "platform": "macOS",
                "events": events.prefix(count).map { $0.serialized() },
            ]
            if let body = try? JSONSerialization.data(withJSONObject: payload), body.count <= maxBytes {
                return (body, count)
            }
            count = count > 1 ? count / 2 : 0
        }
        return nil
    }

    private func recordFailure() {
        consecutiveFailures += 1
        nextFlushAllowed = Date().addingTimeInterval(Self.backoffSeconds(afterFailures: consecutiveFailures))
    }

    nonisolated static func backoffSeconds(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(30 * 60, flushIntervalSeconds * pow(2, Double(min(failures, 10) - 1)))
    }

    nonisolated static func isPermanentRejection(_ statusCode: Int) -> Bool {
        (400 ..< 500).contains(statusCode) && statusCode != 408 && statusCode != 429
    }

    private func persistOutbox() {
        let serialized = outbox.map { $0.serialized() }
        guard let data = try? JSONSerialization.data(withJSONObject: serialized) else { return }
        UserDefaults.standard.set(data, forKey: outboxKey)
    }

    private func anonymousID() -> String {
        if let existing = UserDefaults.standard.string(forKey: "anonymousUserID"), !existing.isEmpty {
            userID = existing
            return existing
        }
        let fresh = UUID().uuidString
        userID = fresh
        UserDefaults.standard.set(fresh, forKey: "anonymousUserID")
        return fresh
    }

    private static func loadOutbox() -> [Event] {
        guard let data = UserDefaults.standard.data(forKey: "metrics_outbox_v2"),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }
        return arr.compactMap(Event.fromSerialized)
    }
}

@MainActor
final class MetricsFlushDriver {
    static let shared = MetricsFlushDriver()
    private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(
            withTimeInterval: MetricsService.flushIntervalSeconds,
            repeats: true
        ) { _ in
            MetricsService.shared.flush()
            MetricsService.sendDailyUsageIfDue()
        }
        MetricsService.sendDailyUsageIfDue()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

extension MetricsService {
    struct Event {
        let id: String
        let name: String
        let props: [String: Any]
        let timestamp: Date

        init(
            id: String = UUID().uuidString,
            name: String,
            props: [String: Any],
            timestamp: Date
        ) {
            self.id = id
            self.name = name
            self.props = props
            self.timestamp = timestamp
        }

        nonisolated static let allowedNames: Set<String> = [
            "app_launch", "generation", "export",
            "audiobook_upload", "audiobook_play", "gemini_clean",
            "installer_download_started", "installer_download_verified",
            "installer_opened", "installer_failed",
            "speech_failed", "dictation", "audiobook_generated", "audiobook_finished",
            "podcast_script", "podcast_render", "ai_request", "relay_request",
            "library_import", "daily_usage",
        ]

        func serialized() -> [String: Any] {
            [
                "event_id": id,
                "event": name,
                "ts": MetricsService.isoFormatter.string(from: timestamp),
                "props": props,
            ]
        }

        nonisolated static func fromSerialized(_ raw: [String: Any]) -> Event? {
            guard let name = raw["event"] as? String,
                  allowedNames.contains(name) else { return nil }
            let props = raw["props"] as? [String: Any] ?? [:]
            let ts: Date = if let s = raw["ts"] as? String {
                MetricsService.isoFormatter.date(from: s) ?? Date()
            } else {
                Date()
            }
            let id = raw["event_id"] as? String
            return Event(
                id: Self.isValidID(id) ? id! : UUID().uuidString,
                name: name,
                props: Props.sanitizedPayload(props),
                timestamp: ts
            )
        }

        private nonisolated static func isValidID(_ value: String?) -> Bool {
            guard let value else { return false }
            return UUID(uuidString: value) != nil
        }
    }

    enum Props {
        nonisolated static let allowedKeys: [String: @Sendable (Any) -> Any?] = [
            "chars": { ($0 as? Int).flatMap { $0 >= 0 ? $0 : nil } },
            "voice": { Check.string($0, pattern: "^[a-z0-9_:.\\-]{1,64}$") },
            "speed": { v in (v as? Double).flatMap { $0 >= 0.5 && $0 <= 2.0 ? $0 : nil } },
            "audio_seconds": { Check.number($0) },
            "pages": { ($0 as? Int).flatMap { $0 >= 0 ? $0 : nil } },
            "file_kind": { v in
                guard let s = v as? String,
                      AudiobookImportStaging.supportedExtensions.contains(s)
                else { return nil }
                return s
            },
            "book_id_hash": { v in
                guard let s = v as? String,
                      s.count == 64,
                      s.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
                return s
            },
            "chars_out": { ($0 as? Int).flatMap { $0 >= 0 ? $0 : nil } },
            "seconds_played": { v in (v as? Double).flatMap { $0 >= 0 ? $0 : nil } },
            "engine": { Check.member($0, of: Bucket.engines) },
            "source": { Check.member($0, of: Bucket.sources) },
            "first_audio_ms": { Check.int($0, in: 0 ... 600_000) },
            "render_ms": { Check.int($0, in: 0 ... 86_400_000) },
            "words": { Check.int($0, in: 0 ... Int.max) },
            "failure_code": { Check.string($0, pattern: "^[a-z0-9_]{1,48}$") },
            "outcome": { Check.member($0, of: Bucket.outcomes) },
            "language": { Check.string($0, pattern: "^[a-z]{2,3}$") },
            "tidied": { Check.bool($0) },
            "ok": { Check.bool($0) },
            "chapters": { Check.int($0, in: 0 ... 10000) },
            "render_seconds": { Check.number($0) },
            "speakers": { Check.int($0, in: 1 ... 8) },
            "provider": { Check.member($0, of: Bucket.providers) },
            "tool": { Check.member($0, of: Bucket.tools) },
            "latency_ms": { Check.int($0, in: 0 ... 600_000) },
            "client": { Check.member($0, of: Bucket.clients) },
            "kind": { Check.member($0, of: Bucket.importKinds) },
            "day": { Check.string($0, pattern: "^\\d{4}-\\d{2}-\\d{2}$") },
            "listen_seconds": { Check.number($0) },
            "speech_seconds": { Check.number($0) },
            "dictation_seconds": { Check.number($0) },
            "speech_count": { Check.int($0, in: 0 ... Int.max) },
            "dictation_words": { Check.int($0, in: 0 ... Int.max) },
            "ai_requests": { Check.int($0, in: 0 ... Int.max) },
            "active_minutes": { Check.int($0, in: 0 ... Int.max) },
        ]

        nonisolated static func sanitizedPayload(_ raw: [String: Any]) -> [String: Any] {
            var out: [String: Any] = [:]
            for (key, validator) in allowedKeys {
                if let v = raw[key], let cleaned = validator(v) {
                    out[key] = cleaned
                }
            }
            return out
        }
    }
}

extension MetricsService {
    enum Check {
        nonisolated static func isBoolean(_ value: Any) -> Bool {
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }

        nonisolated static func int(_ value: Any, in range: ClosedRange<Int>) -> Int? {
            guard !isBoolean(value), let int = value as? Int, range.contains(int) else { return nil }
            return int
        }

        nonisolated static func number(_ value: Any) -> Double? {
            guard !isBoolean(value) else { return nil }
            let double: Double
            if let int = value as? Int {
                double = Double(int)
            } else if let candidate = value as? Double {
                double = candidate
            } else {
                return nil
            }
            return double.isFinite && double >= 0 ? double : nil
        }

        nonisolated static func bool(_ value: Any) -> Bool? {
            isBoolean(value) ? value as? Bool : nil
        }

        nonisolated static func string(_ value: Any, pattern: String) -> String? {
            guard let string = value as? String, string.utf8.count <= 128,
                  string.range(of: pattern, options: .regularExpression) == string.startIndex ..< string.endIndex
            else { return nil }
            return string
        }

        nonisolated static func member(_ value: Any, of allowed: Set<String>) -> String? {
            guard let string = value as? String, allowed.contains(string) else { return nil }
            return string
        }
    }

    enum Bucket {
        nonisolated static let engines: Set<String> = ["kokoro", "ming", "supertonic", "blend", "other"]
        nonisolated static let sources: Set<String> = Set(SpeechSource.allCases.map(\.rawValue))
        nonisolated static let outcomes: Set<String> = [
            "pasted", "copied", "copied_needs_accessibility", "copied_app_changed", "cancelled", "empty",
        ]
        nonisolated static let providers: Set<String> = [
            "openai", "anthropic", "gemini", "groq", "openrouter", "ollama", "lmstudio", "mistral", "deepseek",
            "xai", "custom", "other",
        ]
        nonisolated static let tools: Set<String> = [
            "summarize", "translate", "ask", "quiz", "flashcards", "tidy", "podcast_script",
        ]
        nonisolated static let clients: Set<String> = [
            "claude", "cursor", "codex", "chatgpt", "raycast", "vscode", "windsurf", "zed", "cli", "other",
        ]
        nonisolated static let importKinds: Set<String> = [
            "pdf", "epub", "txt", "docx", "md", "html", "web", "inbox", "text", "other",
        ]

        private nonisolated static let clientMatchers: [(client: String, needles: [String])] = [
            ("claude", ["claude", "anthropic"]),
            ("cursor", ["cursor"]),
            ("codex", ["codex"]),
            ("chatgpt", ["chatgpt", "openai"]),
            ("raycast", ["raycast"]),
            ("windsurf", ["windsurf", "codeium"]),
            ("vscode", ["vscode", "visual studio code", "vs code", "code"]),
            ("zed", ["zed"]),
            ("cli", ["cli", "curl", "shell", "terminal", "python", "node"]),
        ]

        nonisolated static func engine(_ raw: String) -> String {
            let id = raw.lowercased()
            if VoiceBlendRules.isBlendID(id) {
                return "blend"
            }
            return engines.contains(id) ? id : "other"
        }

        nonisolated static func voice(_ raw: String) -> String {
            if VoiceBlendRules.isBlendID(raw) {
                return "blend"
            }
            if SpeechEngineID.isCustomMingVoice(raw) {
                return "ming:custom"
            }
            return raw.lowercased()
        }

        nonisolated static func provider(_ raw: String) -> String {
            let id = raw.lowercased()
            if id == "google" {
                return "gemini"
            }
            return providers.contains(id) ? id : "other"
        }

        nonisolated static func client(_ raw: String?) -> String {
            let name = raw?.lowercased() ?? ""
            if name.isEmpty {
                return "other"
            }
            if let exact = clients.first(where: { $0 == name }) {
                return exact
            }
            let words = Set(name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            for matcher in clientMatchers {
                let hit = matcher.needles.contains { needle in
                    needle.count <= 4 ? words.contains(needle) : name.contains(needle)
                }
                if hit {
                    return matcher.client
                }
            }
            return "other"
        }

        nonisolated static func language(_ raw: String?) -> String? {
            guard let raw, !raw.isEmpty else { return nil }
            let code = raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
            return Check.string(code, pattern: "^[a-z]{2,3}$")
        }

        nonisolated static func failureCode(_ raw: String) -> String {
            let folded = raw.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" }
            let code = String(folded.prefix(48))
            return code.isEmpty ? "unknown" : code
        }

        nonisolated static func speechFailureCode(for error: Error) -> String {
            if let stream = error as? BackendService.StreamError {
                switch stream {
                case .requestEncodingFailed: return "request_encoding_failed"
                case let .rejectedResponse(statusCode): return "rejected_\(statusCode)"
                case .unexpectedResponse: return "unexpected_response"
                case .emptyAudio: return "empty_audio"
                }
            }
            return error is URLError ? "network_error" : "engine_unreachable"
        }

        nonisolated static func importKind(_ raw: String) -> String {
            let kind = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            switch kind {
            case "htm": return "html"
            case "markdown": return "md"
            case "rtf", "text": return "text"
            default: return importKinds.contains(kind) ? kind : "other"
            }
        }
    }
}

extension MetricsService {
    @MainActor
    static func sendDailyUsageIfDue(
        now: Date = Date(),
        defaults: UserDefaults = .standard,
        ledger: UsageLedger? = nil,
        calendar: Calendar = .current,
        send: ((String, DayUsage) -> Void)? = nil
    ) {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return }
        let yesterdayKey = UsageLedger.dayKey(for: yesterday, calendar: calendar)
        if let last = defaults.string(forKey: lastDailyUsageKey), last >= yesterdayKey {
            return
        }
        #if DEBUG
            if ledger == nil, UsageStatsStore.shared.isDemo {
                return
            }
        #endif
        defaults.set(yesterdayKey, forKey: lastDailyUsageKey)
        guard userAllowsAnalytics(defaults) else { return }
        let source = ledger ?? UsageStatsStore.shared.ledger
        guard let usage = source.days[yesterdayKey], usage.isActive else { return }
        if let send {
            send(yesterdayKey, usage)
        } else {
            shared.trackDailyUsage(day: yesterdayKey, usage: usage)
        }
    }
}
