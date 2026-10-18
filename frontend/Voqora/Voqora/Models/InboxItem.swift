import Foundation

nonisolated struct InboxItem: Codable, Identifiable, Equatable, Sendable {
    static let finishedThreshold = 0.98

    let id: UUID
    var title: String
    var siteName: String?
    var byline: String?
    var url: URL
    var language: String?
    var wordCount: Int
    let addedAt: Date
    var progress: Double
    var isArchived: Bool

    var isFinished: Bool {
        progress >= Self.finishedThreshold
    }

    var isUnread: Bool {
        !isArchived && !isFinished
    }

    var siteLabel: String {
        if let siteName, !siteName.isEmpty {
            return siteName
        }
        return InboxLinkParser.displayHost(of: url) ?? url.absoluteString
    }
}

nonisolated struct InboxArticleBody: Codable, Equatable, Sendable {
    let text: String
    let markdown: String
}

nonisolated enum InboxFilter: String, CaseIterable, Identifiable, Sendable {
    case unread
    case archived
    case all

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .unread: "Unread"
        case .archived: "Archived"
        case .all: "All"
        }
    }

    func includes(_ item: InboxItem) -> Bool {
        switch self {
        case .unread: item.isUnread
        case .archived: item.isArchived
        case .all: true
        }
    }

    static func visible(_ items: [InboxItem], filter: InboxFilter, query: String) -> [InboxItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            guard filter.includes(item) else { return false }
            guard !needle.isEmpty else { return true }
            return item.title.localizedCaseInsensitiveContains(needle)
                || item.siteLabel.localizedCaseInsensitiveContains(needle)
        }
    }
}

nonisolated enum InboxListeningTime {
    static let wordsPerMinuteAtNormalSpeed = 165.0
    static let speedRange = 0.5 ... 2.0

    static func minutes(wordCount: Int, speed: Double) -> Int {
        guard wordCount > 0 else { return 0 }
        let clampedSpeed = speed.isFinite ? min(max(speed, speedRange.lowerBound), speedRange.upperBound) : 1.0
        let minutes = Double(wordCount) / (wordsPerMinuteAtNormalSpeed * clampedSpeed)
        return max(1, Int(minutes.rounded(.up)))
    }

    static func label(wordCount: Int, speed: Double) -> String {
        let total = minutes(wordCount: wordCount, speed: speed)
        guard total >= 60 else { return "\(total) min listen" }
        let hours = total / 60
        let remainder = total % 60
        return remainder == 0 ? "\(hours) hr listen" : "\(hours) hr \(remainder) min listen"
    }
}
