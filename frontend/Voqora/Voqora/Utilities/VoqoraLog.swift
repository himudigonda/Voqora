import Foundation

/// Structured logging matching the backend's JSON-line shape (ts/level/
/// logger/msg + optional context) — see `backend/app/core/logging.py` —
/// so `frontend.log` and `backend.log` read the same way once exported
/// together. Replaces ad-hoc `print()` calls (mixed emoji-as-severity, no
/// timestamps, no consistent component tagging) that made exported debug
/// logs hard to search or correlate across the two processes.
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

    /// Exported diagnostics are not a content store. Keep the allowlisted
    /// operational fields, but never serialize error bodies, paths, selected
    /// prose, credentials, or the per-launch IPC capability by accident.
    /// This is deliberately centralized because logging calls are distributed
    /// across UI, audio, and transport code.
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
            if sensitiveKey || sensitiveValue {
                safe["\(key)_redacted"] = "true"
            } else {
                safe[key] = String(value.prefix(256))
            }
        }
        return safe
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
            // All-String payload should always encode; this is a last-resort
            // fallback so a logging failure never crashes the app or leaves
            // a caller's event silently dropped.
            print("{\"ts\":\"\(isoFormatter.string(from: Date()))\",\"level\":\"\(level.rawValue)\",\"logger\":\"\(logger)\",\"msg\":\"logging_encode_failed\"}")
        }
    }
}
