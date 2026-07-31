import Foundation
import SwiftUI

/// MetricsService v3 — counts-only analytics with a whitelisted outbox.
///
/// Design contract:
/// - Sends ONLY the keys in `Props.allowedKeys`. Any unknown key is dropped
///   on the client *before* HTTP serialization. The server re-enforces this.
/// - Launches flush immediately; other events batch every 30s or at 20 events.
/// - Always anonymous: every request carries `anon_id` (a stable per-install
///   UUID owned by `IdentityService`) and never a bearer token. Email-based
///   identity is handled separately by `IdentityService.submitEmail`, which
///   POSTs to `/api/voqora/identify` and is independent from event flush.
/// - Honors the `telemetryEnabled` toggle as a hard kill switch.
/// - Outbox is persisted to UserDefaults across app restarts (cap 200).
/// - Endpoint: POST /api/voqora/events on himudigonda.me.
actor MetricsService {
    static let shared = MetricsService()

    private let endpoint = URL(string: "https://himudigonda.me/api/voqora/events")!
    private let outboxKey = "metrics_outbox_v2"
    private let outboxCap = 200
    private let flushBatchSize = 20
    nonisolated static let flushIntervalSeconds: TimeInterval = 30

    // State now lives inside the actor — no @AppStorage main-thread coupling.
    // UserDefaults itself is thread-safe per Apple docs; we read it at init
    // and on the toggle path, which is rare.
    private var userID: String
    private var enabled: Bool
    private var outbox: [Event] = []
    private var isFlushing = false

    /// Static so `Event.serialized()` doesn't reallocate per call.
    /// `ISO8601DateFormatter` is documented as thread-safe by Apple but is
    /// not Sendable; use `nonisolated(unsafe)` to opt out of the audit.
    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        let stored = UserDefaults.standard.string(forKey: "anonymousUserID")
        if let s = stored, !s.isEmpty {
            self.userID = s
        } else {
            let fresh = UUID().uuidString
            UserDefaults.standard.set(fresh, forKey: "anonymousUserID")
            self.userID = fresh
        }
        let enabledRaw = UserDefaults.standard.object(forKey: "telemetryEnabled") as? Bool
        self.enabled = enabledRaw ?? true
        self.outbox = Self.loadOutbox()
    }

    // MARK: - Configuration

    /// Toggle telemetry. When disabled, outbox is cleared.
    func setEnabled(_ value: Bool) {
        self.enabled = value
        UserDefaults.standard.set(value, forKey: "telemetryEnabled")
        if !value {
            outbox.removeAll()
            persistOutbox()
        }
    }

    /// Current enabled state — useful for UI toggles.
    func isEnabled() -> Bool { enabled }

    // MARK: - Public surface (fire-and-forget, call-site compatible with v1)

    nonisolated func trackLaunch() {
        Task { await self.enqueue(event: "app_launch", props: [:], flushImmediately: true) }
    }

    nonisolated func trackGeneration(chars: Int, voice: String, speed: Double, audioSeconds: Double) {
        Task {
            await self.enqueue(event: "generation", props: [
                "chars": chars,
                "voice": voice,
                "speed": speed,
                "audio_seconds": audioSeconds,
            ])
        }
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

    nonisolated func trackGeminiClean(pages: Int, charsOut: Int) {
        Task {
            await self.enqueue(event: "gemini_clean",
                               props: ["pages": pages, "chars_out": charsOut])
        }
    }

    /// Installer signals describe the handoff funnel, never a completed app
    /// installation or a unique person. The DMG still requires an explicit
    /// Finder drag-and-drop step by the user.
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

    /// Fire-and-forget force-flush. Safe to call from anywhere.
    nonisolated func flush() {
        Task { await self.flushLocked() }
    }

    // MARK: - Core

    private func enqueue(
        event: String,
        props rawProps: [String: Any],
        flushImmediately: Bool = false
    ) async {
        guard enabled else { return }
        guard Event.allowedNames.contains(event) else {
            #if DEBUG
            print("⚠️ Metrics: unknown event '\(event)' dropped")
            #endif
            return
        }
        let cleanedProps = Props.whitelist(rawProps)
        // The identifier is generated before persistence, so a retry after a
        // lost HTTP response is the same event, not a second launch/action.
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
        guard enabled else {
            outbox.removeAll()
            persistOutbox()
            return
        }
        guard !isFlushing, !outbox.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }
        let batch = Array(outbox.prefix(flushBatchSize))
        let payload: [String: Any] = [
            "anon_id": userID,
            "product": "voqora",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            "platform": "macOS",
            "events": batch.map { $0.serialized() },
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            #if DEBUG
            print("⚠️ Metrics: serialization failed; retaining batch")
            #endif
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        // Keep the batch until the server confirms acceptance. The actor guard
        // prevents concurrent timer/manual flushes from sending duplicates.
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            guard (200..<300).contains(http.statusCode) else {
                #if DEBUG
                print("📡 Metrics: server rejected batch → \(http.statusCode); retaining it")
                #endif
                return
            }
            outbox.removeFirst(min(batch.count, outbox.count))
            persistOutbox()
            #if DEBUG
            print("📡 Metrics: flushed \(batch.count) events → \(http.statusCode)")
            #endif
        } catch {
            #if DEBUG
            print("📡 Metrics: flush failed — \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Outbox persistence

    private func persistOutbox() {
        let serialized = outbox.map { $0.serialized() }
        guard let data = try? JSONSerialization.data(withJSONObject: serialized) else { return }
        UserDefaults.standard.set(data, forKey: outboxKey)
    }

    private static func loadOutbox() -> [Event] {
        guard let data = UserDefaults.standard.data(forKey: "metrics_outbox_v2"),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap(Event.fromSerialized)
    }
}

// MARK: - Periodic flush driver
//
// Lives on @MainActor so the Timer schedules on the main runloop (safe and
// matches the original behavior). Each tick spawns a Task that hops into the
// MetricsService actor to flush.
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
            // `flush()` is nonisolated and spawns its own Task; no await needed.
            MetricsService.shared.flush()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Event + Props (testable boundary; UNCHANGED API)

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
        ]

        func serialized() -> [String: Any] {
            return [
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
            let ts: Date
            if let s = raw["ts"] as? String {
                ts = MetricsService.isoFormatter.date(from: s) ?? Date()
            } else {
                ts = Date()
            }
            // Pre-idempotency outbox entries remain safe to deliver: assign a
            // fresh ID once and persist it with the next outbox write.
            let id = raw["event_id"] as? String
            return Event(
                id: Self.isValidID(id) ? id! : UUID().uuidString,
                name: name,
                props: Props.whitelist(props),
                timestamp: ts
            )
        }

        private nonisolated static func isValidID(_ value: String?) -> Bool {
            guard let value else { return false }
            return UUID(uuidString: value) != nil
        }
    }

    enum Props {
        /// Closed whitelist — see `docs/specs/accounts-analytics.md` §5.2.
        /// Any key not in this map is dropped.
        nonisolated static let allowedKeys: [String: @Sendable (Any) -> Any?] = [
            "chars":          { ($0 as? Int).flatMap { $0 >= 0 ? $0 : nil } },
            "voice":          { ($0 as? String) },
            "speed":          { v in (v as? Double).flatMap { $0 >= 0.5 && $0 <= 2.0 ? $0 : nil } },
            "volume":         { v in (v as? Double).flatMap { $0 >= 0.0 && $0 <= 1.5 ? $0 : nil } },
            "audio_seconds":  { v in (v as? Double).flatMap { $0 >= 0 ? $0 : nil } },
            "pages":          { ($0 as? Int).flatMap { $0 >= 0 ? $0 : nil } },
            "file_kind":      { v in
                guard let s = v as? String,
                      AudiobookImportStaging.supportedExtensions.contains(s)
                else { return nil }
                return s
            },
            "book_id_hash":   { v in
                guard let s = v as? String,
                      s.count == 64,
                      s.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
                return s
            },
            "chars_out":      { ($0 as? Int).flatMap { $0 >= 0 ? $0 : nil } },
            "seconds_played": { v in (v as? Double).flatMap { $0 >= 0 ? $0 : nil } },
        ]

        /// Strip everything not in `allowedKeys` and validate value shapes.
        /// This is *defense in depth*; the server enforces the same whitelist.
        nonisolated static func whitelist(_ raw: [String: Any]) -> [String: Any] {
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
