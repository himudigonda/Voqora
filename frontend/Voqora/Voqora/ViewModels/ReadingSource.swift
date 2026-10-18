import Foundation

enum ReadingSource: Equatable {
    case audiobook
    case speech
    case loading
    case unavailable
    case empty

    static func resolve(audiobookTranscript: AudiobookViewModel.TranscriptState?, hasSpokenText: Bool) -> ReadingSource {
        guard let audiobookTranscript else { return hasSpokenText ? .speech : .empty }
        switch audiobookTranscript {
        case .loaded: return .audiobook
        case .idle, .loading: return .loading
        case .unavailable: return .unavailable
        }
    }
}
