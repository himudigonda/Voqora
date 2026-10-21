import Foundation

nonisolated enum DictationTrace {
    static let defaultsKey = "dictationDebugTrace"

    static var isEnabled: Bool {
        #if DEBUG
            true
        #else
            UserDefaults.standard.bool(forKey: defaultsKey)
        #endif
    }

    private static let writer = DictationTraceWriter(
        directory: DictationTraceWriter.defaultDirectory,
        includesText: includesText,
        mirror: { name, fields in
            Task { @MainActor in VoqoraLog.debug("DictationTrace", name, fields) }
        }
    )

    private static var includesText: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    static func beginSession(engine: String, locale: String?) {
        guard isEnabled else { return }
        writer.beginSession(engine: engine, locale: locale)
    }

    static func event(_ name: String, _ fields: [String: String] = [:]) {
        guard isEnabled else { return }
        writer.event(name, fields)
    }

    static func endSession(outcome: String) {
        guard isEnabled else { return }
        writer.endSession(outcome: outcome)
    }
}

final nonisolated class DictationTraceWriter: @unchecked Sendable {
    typealias Mirror = @Sendable (String, [String: String]) -> Void

    static let defaultRetention = 20

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Voqora", isDirectory: true)
            .appendingPathComponent("dictation-debug", isDirectory: true)
    }

    private let directory: URL
    private let includesText: Bool
    private let retention: Int
    private let mirror: Mirror?
    private let queue = DispatchQueue(label: "com.voqora.dictation-trace")
    private let stampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private var handle: FileHandle?
    private var sessionStart: UInt64 = 0
    private var lastSessionStamp = Date.distantPast

    init(directory: URL, includesText: Bool, retention: Int = DictationTraceWriter.defaultRetention, mirror: Mirror? = nil) {
        self.directory = directory
        self.includesText = includesText
        self.retention = retention
        self.mirror = mirror
    }

    func beginSession(engine: String, locale: String?) {
        let now = Date()
        let uptime = DispatchTime.now().uptimeNanoseconds
        queue.async { [self] in
            openSession(at: now, uptime: uptime)
            write("session.begin", ["engine": engine, "locale": locale ?? "system"], at: now, uptime: uptime)
        }
    }

    func event(_ name: String, _ fields: [String: String] = [:]) {
        let now = Date()
        let uptime = DispatchTime.now().uptimeNanoseconds
        queue.async { [self] in
            write(name, fields, at: now, uptime: uptime)
        }
    }

    func endSession(outcome: String) {
        let now = Date()
        let uptime = DispatchTime.now().uptimeNanoseconds
        queue.async { [self] in
            write("session.end", ["outcome": outcome], at: now, uptime: uptime)
            try? handle?.close()
            handle = nil
        }
    }

    func flush() {
        queue.sync {}
    }

    private func openSession(at date: Date, uptime: UInt64) {
        try? handle?.close()
        handle = nil
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = max(date, lastSessionStamp.addingTimeInterval(0.001))
        lastSessionStamp = stamp
        let name = stampFormatter.string(from: stamp).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("session-\(name).jsonl")
        guard manager.createFile(atPath: url.path, contents: nil) else { return }
        handle = try? FileHandle(forWritingTo: url)
        sessionStart = uptime
        prune()
    }

    private func prune() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let sessions = files
            .filter { $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for stale in sessions.dropLast(max(retention, 1)) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    private func write(_ name: String, _ fields: [String: String], at date: Date, uptime: UInt64) {
        guard let handle else { return }
        let elapsed = uptime >= sessionStart ? (uptime - sessionStart) / 1_000_000 : 0
        let recorded = includesText ? fields : Self.countingText(in: fields)
        let object: [String: Any] = [
            "ts": stampFormatter.string(from: date),
            "ms": Int(elapsed),
            "name": name,
            "fields": recorded,
        ]
        if var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            data.append(0x0A)
            try? handle.write(contentsOf: data)
        }
        mirror?(name, includesText ? Self.countingText(in: fields) : recorded)
    }

    private static func countingText(in fields: [String: String]) -> [String: String] {
        var counted: [String: String] = [:]
        for (key, value) in fields {
            if key.lowercased().contains("text") {
                counted["\(key)Chars"] = "\(value.count)"
                counted["\(key)Words"] = "\(value.split(whereSeparator: \.isWhitespace).count)"
            } else {
                counted[key] = value
            }
        }
        return counted
    }
}
