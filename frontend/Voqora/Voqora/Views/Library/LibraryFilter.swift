import Foundation

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case audiobooks
    case podcasts
    case inProgress
    case finished
    case processing

    static let finishedThreshold = 0.98
    static let startedThreshold = 0.005

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all: "All"
        case .audiobooks: "Audiobooks"
        case .podcasts: "Podcasts"
        case .inProgress: "In progress"
        case .finished: "Finished"
        case .processing: "Processing"
        }
    }

    func includes(_ book: Audiobook, status: ProcessingStatus, listenedFraction: Double) -> Bool {
        switch self {
        case .all: true
        case .audiobooks: !book.isPodcast
        case .podcasts: book.isPodcast
        case .inProgress: status.isReady && listenedFraction > Self.startedThreshold && listenedFraction < Self.finishedThreshold
        case .finished: status.isReady && listenedFraction >= Self.finishedThreshold
        case .processing: status.isProcessing
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: "Nothing here yet."
        case .audiobooks: "No audiobooks match this filter."
        case .podcasts: "Podcasts you render from a script appear here."
        case .inProgress: "Books you have started but not finished appear here."
        case .finished: "Books you have listened to the end appear here."
        case .processing: "Nothing is being processed right now."
        }
    }
}

enum LibrarySortMode: String, CaseIterable, Identifiable {
    case recent
    case alpha
    case duration

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .recent: "Date Added"
        case .alpha: "Title"
        case .duration: "Length"
        }
    }

    func sorted(_ books: [Audiobook]) -> [Audiobook] {
        switch self {
        case .recent:
            books.sorted { $0.createdAt > $1.createdAt }
        case .alpha:
            books.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        case .duration:
            books.sorted { $0.totalAudioSeconds > $1.totalAudioSeconds }
        }
    }
}
