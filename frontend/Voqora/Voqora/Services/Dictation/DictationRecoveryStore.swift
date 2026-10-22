import Foundation

nonisolated struct DictationInflightSession: Codable, Equatable, Sendable {
    let sessionID: Int
    let startedAt: Date
    let localeIdentifier: String?
    let text: String
}

@MainActor
final class DictationRecoveryStore {
    static let throttleSeconds: TimeInterval = 0.5

    private let fileURL: URL
    private let clock: () -> TimeInterval
    private var lastWrite: TimeInterval?
    private var pendingSession: DictationInflightSession?
    private var trailingWrite: Task<Void, Never>?

    static func defaultURL() -> URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID)
            .appendingPathComponent("dictation-inflight.json")
    }

    init(fileURL: URL? = nil, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.fileURL = fileURL ?? Self.defaultURL()
        self.clock = clock
    }

    func record(_ session: DictationInflightSession, force: Bool = false) {
        let now = clock()
        if !force, let lastWrite, now - lastWrite < Self.throttleSeconds {
            scheduleTrailingWrite(of: session, after: Self.throttleSeconds - (now - lastWrite))
            return
        }
        cancelTrailingWrite()
        write(session, at: now)
    }

    private func scheduleTrailingWrite(of session: DictationInflightSession, after delay: TimeInterval) {
        pendingSession = session
        guard trailingWrite == nil else { return }
        trailingWrite = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushTrailingWrite()
        }
    }

    private func flushTrailingWrite() {
        let session = pendingSession
        cancelTrailingWrite()
        guard let session else { return }
        write(session, at: clock())
    }

    private func cancelTrailingWrite() {
        trailingWrite?.cancel()
        trailingWrite = nil
        pendingSession = nil
    }

    private func write(_ session: DictationInflightSession, at now: TimeInterval) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return }
        lastWrite = now
    }

    func pending() -> DictationInflightSession? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(DictationInflightSession.self, from: data)
    }

    func clear() {
        cancelTrailingWrite()
        lastWrite = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
}
