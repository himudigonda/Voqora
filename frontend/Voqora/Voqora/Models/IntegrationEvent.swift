import Foundation

nonisolated struct RelaySpeakCommand: Equatable, Sendable {
    let id: String
    let text: String
    let voice: String?
    let client: String?
}

nonisolated enum IntegrationEvent: Equatable, Sendable {
    case ready
    case speak(RelaySpeakCommand)
    case stop(id: String)
}

nonisolated enum IntegrationEventParser {
    static let dataPrefix = "data:"
    static let maximumClientNameLength = 40
    static let maximumVoiceLength = 64

    private struct Payload: Decodable {
        let type: String
        let id: String?
        let text: String?
        let voice: String?
        let client: String?
    }

    static func event(fromLine line: String) -> IntegrationEvent? {
        guard line.hasPrefix(dataPrefix) else { return nil }
        let json = line.dropFirst(dataPrefix.count).trimmingCharacters(in: .whitespaces)
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else { return nil }
        switch payload.type {
        case "ready":
            return .ready
        case "speak":
            guard let id = payload.id, let text = payload.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return .speak(RelaySpeakCommand(
                id: id,
                text: text,
                voice: voiceID(payload.voice),
                client: clientName(payload.client)
            ))
        case "stop":
            return payload.id.map { .stop(id: $0) }
        default:
            return nil
        }
    }

    static func voiceID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed.count <= maximumVoiceLength
        else { return nil }
        return trimmed
    }

    static func clientName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let printable = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        let collapsed = printable.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let limited = String(collapsed.prefix(maximumClientNameLength))
        return limited.isEmpty ? nil : limited
    }
}
