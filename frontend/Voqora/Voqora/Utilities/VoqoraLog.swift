import Foundation

enum VoqoraLog {
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    static func debug(_ logger: String, _ msg: String, _ context: [String: String] = [:]) {
        emit(.debug, logger, msg, context)
    }

    static func info(_ logger: String, _ msg: String, _ context: [String: String] = [:]) {
        emit(.info, logger, msg, context)
    }

    static func warn(_ logger: String, _ msg: String, _ context: [String: String] = [:]) {
        emit(.warn, logger, msg, context)
    }

    static func error(_ logger: String, _ msg: String, _ context: [String: String] = [:]) {
        emit(.error, logger, msg, context)
    }

    private struct LogEvent: Encodable {
        let ts: String
        let level: String
        let logger: String
        let msg: String
        let context: [String: String]?
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func redactedContext(_ context: [String: String]) -> [String: String] {
        var safe: [String: String] = [:]
        for (key, value) in context {
            let normalized = key.lowercased()
            let sensitiveKey = [
                "error", "exception", "text", "content", "prompt", "path",
                "key", "token", "authorization", "credential", "payload",
            ].contains { normalized.contains($0) }
            let sensitiveValue = value.localizedCaseInsensitiveContains("AIza")
                || value.localizedCaseInsensitiveContains("bearer ")
                || value.localizedCaseInsensitiveContains("x-voqora-ipc-token")
                || containsLocalIdentity(value)
            if sensitiveKey || sensitiveValue {
                safe["\(key)_redacted"] = "true"
            } else {
                safe[key] = String(value.prefix(256))
            }
        }
        return safe
    }

    private static func containsLocalIdentity(_ value: String) -> Bool {
        let account = NSUserName()
        if !account.isEmpty, value.localizedCaseInsensitiveContains(account) {
            return true
        }
        let home = NSHomeDirectory()
        if !home.isEmpty, home != "/", value.contains(home) {
            return true
        }
        return false
    }

    private static func emit(_ level: Level, _ logger: String, _ msg: String, _ context: [String: String]) {
        let safeContext = redactedContext(context)
        let event = LogEvent(
            ts: isoFormatter.string(from: Date()),
            level: level.rawValue,
            logger: logger,
            msg: msg,
            context: safeContext.isEmpty ? nil : safeContext
        )
        if let data = try? encoder.encode(event), let line = String(data: data, encoding: .utf8) {
            print(line)
        } else {
            print("{\"ts\":\"\(isoFormatter.string(from: Date()))\",\"level\":\"\(level.rawValue)\",\"logger\":\"\(logger)\",\"msg\":\"logging_encode_failed\"}")
        }
    }
}
