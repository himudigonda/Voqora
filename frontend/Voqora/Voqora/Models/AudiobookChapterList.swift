import Foundation

nonisolated struct AudiobookChapterList: Decodable, Equatable, Sendable {
    struct Chapter: Decodable, Equatable, Sendable {
        let title: String
        let startSeconds: Double
        let endSeconds: Double

        enum CodingKeys: String, CodingKey {
            case title
            case startSeconds = "start_seconds"
            case endSeconds = "end_seconds"
        }
    }

    let totalAudioSeconds: Double
    let chapters: [Chapter]

    enum CodingKeys: String, CodingKey {
        case totalAudioSeconds = "total_audio_seconds"
        case chapters
    }
}

nonisolated enum AudiobookSubtitleFormat: String, Sendable {
    case srt
    case vtt
}
