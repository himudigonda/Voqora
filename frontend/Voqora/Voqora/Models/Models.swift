import Foundation

enum AppStatus: Equatable {
    case ready
    case thinking
    case speaking
    case paused
    case error(String)

    var message: String {
        switch self {
        case .ready: "Ready"
        case .thinking: "AI is Processing..."
        case .speaking: "Speaking"
        case .paused: "Paused"
        case let .error(m): m
        }
    }
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date
    let voice: String
    var isFavorite: Bool

    init(text: String, voice: String, isFavorite: Bool = false) {
        id = UUID()
        self.text = text
        timestamp = Date()
        self.voice = voice
        self.isFavorite = isFavorite
    }
}
