import Combine
import Foundation

@MainActor
final class UsageStatsStore: ObservableObject {
    static let shared = UsageStatsStore(
        storageURL: RuntimeEnvironment.isRunningTests
            ? FileManager.default.temporaryDirectory.appendingPathComponent("voqora-usage-\(UUID().uuidString).json")
            : nil
    )

    @Published private(set) var ledger = UsageLedger()
    @Published private(set) var persistenceError: String?

    let calendar: Calendar
    private let storageURL: URL
    private let saveDelay: Duration
    private var saveTask: Task<Void, Never>?
    private var listeningBookID: String?
    private var lastListeningTick: Date?
    private var pendingListening: Double = 0
    private var isErased = false
    static let maxTickGap: TimeInterval = 5
    static let listeningCommitSeconds: Double = 15

    private static func defaultStorageURL() -> URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID)
            .appendingPathComponent("usage-stats.json")
    }

    init(storageURL: URL? = nil, calendar: Calendar = .current, saveDelay: Duration = .seconds(2)) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        self.calendar = calendar
        self.saveDelay = saveDelay
        load()
    }

    func recordSpeech(text: String, voice: String, speed: Double, audioSeconds: Double, at date: Date = Date()) {
        mutate { $0.recordSpeech(SpeechSample(text: text, voice: voice, speed: speed, audioSeconds: audioSeconds), at: date, calendar: calendar) }
    }

    func recordExport(at date: Date = Date()) {
        mutate { $0.recordExport(at: date, calendar: calendar) }
    }

    func recordDocumentAdded(pages: Int, at date: Date = Date()) {
        mutate { $0.recordDocumentAdded(pages: pages, at: date, calendar: calendar) }
    }

    func recordLaunch(at date: Date = Date()) {
        mutate { $0.recordLaunch(at: date, calendar: calendar) }
    }

    func importHistoryIfNeeded(_ entries: [HistoryEntry]) {
        guard !ledger.importedHistory else { return }
        mutate { $0.importHistory(entries, calendar: calendar) }
    }

    func listeningTick(bookID: String?, isPlaying: Bool, now: Date = Date()) {
        if let bookID, bookID == listeningBookID, let last = lastListeningTick {
            let delta = now.timeIntervalSince(last)
            if delta > 0, delta <= Self.maxTickGap {
                pendingListening += delta
            }
        }
        if bookID != listeningBookID || !isPlaying || pendingListening >= Self.listeningCommitSeconds {
            commitListening(at: now)
        }
        listeningBookID = isPlaying ? bookID : nil
        lastListeningTick = isPlaying && bookID != nil ? now : nil
    }

    func commitListening(at date: Date = Date()) {
        guard let bookID = listeningBookID, pendingListening > 0 else {
            pendingListening = 0
            return
        }
        let seconds = pendingListening
        pendingListening = 0
        mutate { $0.recordListening(bookID: bookID, seconds: seconds, at: date, calendar: calendar) }
    }

    func reset() {
        listeningBookID = nil
        lastListeningTick = nil
        pendingListening = 0
        ledger = UsageLedger(importedHistory: true)
        saveNow()
    }

    func eraseAll() throws {
        saveTask?.cancel()
        saveTask = nil
        listeningBookID = nil
        lastListeningTick = nil
        pendingListening = 0
        ledger = UsageLedger()
        persistenceError = nil
        isErased = true
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        try FileManager.default.removeItem(at: storageURL)
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard !isErased else { return }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(ledger).write(to: storageURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = "Stats could not be saved on this Mac."
        }
    }

    private func mutate(_ change: (inout UsageLedger) -> Void) {
        guard !isErased else { return }
        change(&ledger)
        scheduleSave()
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveTask = nil
            self?.saveNow()
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            ledger = try decoder.decode(UsageLedger.self, from: Data(contentsOf: storageURL))
        } catch {
            let backup = storageURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: storageURL, to: backup)
            persistenceError = "Earlier stats could not be read. New activity is still counted."
        }
    }
}
