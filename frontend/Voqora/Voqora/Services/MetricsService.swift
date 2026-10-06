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

    private var userID: String?
    private var enabled: Bool
    private var outbox: [Event] = []
    private var isFlushing = false
    private var consecutiveFailures = 0
    private var nextFlushAllowed = Date.distantPast

    nonisolated static func userAllowsAnalytics(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: analyticsEnabledKey) as? Bool ?? true
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
    }

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
        isFlushing = true
        defer { isFlushing = false }
        let batch = Array(outbox.prefix(flushBatchSize))
        let payload: [String: Any] = [
            "anon_id": anonymousID(),
            "product": "voqora",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            "platform": "macOS",
            "events": batch.map { $0.serialized() },
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            await MainActor.run {
                VoqoraLog.error("MetricsService", "Batch serialization failed, retaining batch", ["batchSize": "\(batch.count)"])
            }
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
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
        }
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
            "voice": { ($0 as? String) },
            "speed": { v in (v as? Double).flatMap { $0 >= 0.5 && $0 <= 2.0 ? $0 : nil } },
            "audio_seconds": { v in (v as? Double).flatMap { $0 >= 0 ? $0 : nil } },
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
