import Foundation

struct Audiobook: Identifiable, Codable, Hashable {
    let bookID: String
    let title: String
    let createdAt: String
    let pageCount: Int
    let status: String
    let phaseProgress: PhaseProgress
    let sections: [AudiobookSection]
    let pageToTime: [String: Double]
    let totalAudioSeconds: Double
    let failedPages: [Int]
    let estimated: EstimatedStats?
    let actual: ActualStats?
    let engine: String
    let voice: String
    let speed: Double
    let usesGeminiCleanup: Bool?
    let budget: GeminiBudget?
    let error: String?

    var requiresGeminiCleanup: Bool {
        usesGeminiCleanup ?? true
    }

    var id: String {
        bookID
    }

    var displayTitle: String {
        AudiobookImportStaging.strippingSupportedExtension(from: title)
    }

    var narratorName: String {
        DashboardViewModel.voiceName(for: voice)
    }

    var sortedSections: [AudiobookSection] {
        sections.sorted { $0.startTime < $1.startTime }
    }

    func subtitle(at time: TimeInterval, chapters: [AudiobookSection]? = nil) -> String {
        let chapters = chapters ?? sortedSections
        guard chapters.count > 1, let section = chapters.section(at: time) else {
            return "Narrated by \(narratorName)"
        }
        let title = AudiobookImportStaging.strippingSupportedExtension(from: section.title)
        return title.caseInsensitiveCompare(displayTitle) == .orderedSame ? "Narrated by \(narratorName)" : title
    }

    var progressFraction: Double {
        let total = Double(phaseProgress.pageTotal)
        guard total > 0 else { return 0 }
        return Double(phaseProgress.pageDone) / total
    }

    var displayStatus: ProcessingStatus {
        switch status {
        case "ready": .notStarted
        case "queued": .queued
        case "extracting":
            .extracting(page: phaseProgress.pageDone, total: phaseProgress.pageTotal)
        case "cleaning":
            .cleaning(page: phaseProgress.pageDone, total: phaseProgress.pageTotal)
        case "sectioning":
            .sectioning(page: phaseProgress.pageDone, total: phaseProgress.pageTotal)
        case "tts":
            .generating(page: phaseProgress.pageDone, total: phaseProgress.pageTotal)
        case "concatenating":
            .finishing
        case "done":
            .ready
        case "needs_key":
            .needsKey
        case "needs_cost_approval":
            .needsCostApproval(requiredCap: budget?.costApproval?.requiredCapUsd)
        case "failed":
            .failed(reason: error ?? "Unknown error")
        case "cancelled":
            .cancelled
        default:
            .queued
        }
    }

    enum CodingKeys: String, CodingKey {
        case bookID = "book_id"
        case title
        case createdAt = "created_at"
        case pageCount = "page_count"
        case status
        case phaseProgress = "phase_progress"
        case sections
        case pageToTime = "page_to_time"
        case totalAudioSeconds = "total_audio_seconds"
        case failedPages = "failed_pages"
        case estimated, actual, engine, voice, speed, budget
        case usesGeminiCleanup = "uses_gemini_cleanup"
        case error
    }
}

struct GeminiBudget: Codable, Hashable {
    let capUsd: Double?
    let actualUsd: Double?
    let reservedUsd: Double?
    let costApproval: CostApproval?

    struct CostApproval: Codable, Hashable {
        let requiredCapUsd: Double
        let currentCapUsd: Double?
        let tier: String

        enum CodingKeys: String, CodingKey {
            case requiredCapUsd = "required_cap_usd"
            case currentCapUsd = "current_cap_usd"
            case tier
        }
    }

    enum CodingKeys: String, CodingKey {
        case capUsd = "cap_usd"
        case actualUsd = "actual_usd"
        case reservedUsd = "reserved_usd"
        case costApproval = "cost_approval"
    }
}

struct PhaseProgress: Codable, Hashable {
    let pageDone: Int
    let pageTotal: Int

    enum CodingKeys: String, CodingKey {
        case pageDone = "page_done"
        case pageTotal = "page_total"
    }
}

nonisolated struct AudiobookSection: Identifiable, Codable, Hashable, Sendable {
    var id: String {
        "\(startPage)-\(endPage)-\(Int(startTime * 1000))"
    }

    let title: String
    let startPage: Int
    let endPage: Int
    let startTime: Double

    enum CodingKeys: String, CodingKey {
        case title
        case startPage = "start_page"
        case endPage = "end_page"
        case startTime = "start_time"
    }
}

extension [AudiobookSection] {
    func section(at time: TimeInterval) -> AudiobookSection? {
        last { $0.startTime <= time }
    }
}

struct EstimatedStats: Codable, Hashable {
    let pages: Int
    let words: Int
    let audioSeconds: Double
    let processingSeconds: Double
    let costUsd: Double

    enum CodingKeys: String, CodingKey {
        case pages, words
        case audioSeconds = "audio_seconds"
        case processingSeconds = "processing_seconds"
        case costUsd = "cost_usd"
    }
}

struct ActualStats: Codable, Hashable {
    let pages: Int
    let words: Int
    let audioSeconds: Double
    let processingSeconds: Double
    let sections: Int
    let tokensUsed: Int
    let costUsd: Double

    enum CodingKeys: String, CodingKey {
        case pages, words
        case audioSeconds = "audio_seconds"
        case processingSeconds = "processing_seconds"
        case sections
        case tokensUsed = "tokens_used"
        case costUsd = "cost_usd"
    }
}

struct AudiobookEstimateResponse: Codable, Hashable {
    let bookID: String
    let title: String
    let pageCount: Int
    let wordCountEstimate: Int
    let estimatedProcessingSeconds: Double
    let estimatedAudioSeconds: Double
    let estimatedCostUsd: Double
    let maximumCostUsd: Double?
    let estimatedTokenCount: Int
    let isImageOnly: Bool
    let costWarning: Bool
    let duplicateOfBookID: String?
    let duplicateOfTitle: String?

    enum CodingKeys: String, CodingKey {
        case bookID = "book_id"
        case title
        case pageCount = "page_count"
        case wordCountEstimate = "word_count_estimate"
        case estimatedProcessingSeconds = "estimated_processing_seconds"
        case estimatedAudioSeconds = "estimated_audio_seconds"
        case estimatedCostUsd = "estimated_cost_usd"
        case maximumCostUsd = "maximum_cost_usd"
        case estimatedTokenCount = "estimated_token_count"
        case isImageOnly = "is_image_only"
        case costWarning = "cost_warning"
        case duplicateOfBookID = "duplicate_of_book_id"
        case duplicateOfTitle = "duplicate_of_title"
    }
}

enum ProcessingStatus: Hashable {
    case notStarted
    case queued
    case extracting(page: Int, total: Int)
    case cleaning(page: Int, total: Int)
    case sectioning(page: Int, total: Int)
    case generating(page: Int, total: Int)
    case finishing
    case ready
    case needsKey
    case needsCostApproval(requiredCap: Double?)
    case failed(reason: String)
    case cancelled

    var isProcessing: Bool {
        switch self {
        case .extracting, .cleaning, .sectioning, .generating, .finishing, .queued: true
        default: false
        }
    }

    var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }

    var caption: String {
        switch self {
        case .notStarted: "Not started"
        case .queued: "Waiting…"
        case let .extracting(p, t): "Reading page \(p) of \(t)"
        case let .cleaning(p, t): "Cleaning page \(p) of \(t)"
        case .sectioning: "Finding chapters…"
        case let .generating(p, t): "Narrating page \(p) of \(t)"
        case .finishing: "Finishing up…"
        case .ready: "Ready"
        case .needsKey: "Needs Gemini API key"
        case .needsCostApproval: "Needs approval"
        case .failed: "Failed. Click to retry."
        case .cancelled: "Stopped. Click to restart."
        }
    }
}

enum DurationFormatter {
    static func short(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return "\(h)h \(m)m"
        }
        if m > 0 {
            return "\(m)m \(s)s"
        }
        return "\(s)s"
    }

    static func listing(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60 {
            let remainder = minutes % 60
            return remainder == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(remainder) min"
        }
        return minutes > 0 ? "\(minutes) min" : "\(Int(seconds.rounded())) sec"
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
