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

    private static func emit(_ level: Level, _ logger: String, _ msg: String, _ context: [String: String]) {
        let event = LogEvent(
            ts: isoFormatter.string(from: Date()),
            level: level.rawValue,
            logger: logger,
            msg: msg,
            context: context.isEmpty ? nil : context
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
