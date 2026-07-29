import Foundation

/// Mirror of backend `meta.json` schema.
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
    let error: String?

    var id: String { bookID }

    var progressFraction: Double {
        let total = Double(phaseProgress.pageTotal)
        guard total > 0 else { return 0 }
        return Double(phaseProgress.pageDone) / total
    }

    var displayStatus: ProcessingStatus {
        switch status {
        case "ready", "queued": return .queued
        case "extracting":
            return .extracting(page: phaseProgress.pageDone, total: phaseProgress.pageTotal)
        case "cleaning":
            return .cleaning(page: phaseProgress.pageDone, total: phaseProgress.pageTotal)
        case "tts":
            return .generating(page: phaseProgress.pageDone, total: phaseProgress.pageTotal)
        case "concatenating":
            return .generating(page: phaseProgress.pageTotal, total: phaseProgress.pageTotal)
        case "done":
            return .ready
        case "needs_key":
            return .needsKey
        case "failed":
            return .failed(reason: error ?? "Unknown error")
        case "cancelled":
            return .cancelled
        default:
            return .queued
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
        case estimated, actual, engine, voice, speed, error
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

struct AudiobookSection: Identifiable, Codable, Hashable {
    var id: String { "\(startPage)-\(endPage)" }
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

/// Upload-time estimate response from POST /audiobook.
struct AudiobookEstimateResponse: Codable, Hashable {
    let bookID: String
    let title: String
    let pageCount: Int
    let wordCountEstimate: Int
    let estimatedProcessingSeconds: Double
    let estimatedAudioSeconds: Double
    let estimatedCostUsd: Double
    let estimatedTokenCount: Int
    let isImageOnly: Bool
    let costWarning: Bool

    enum CodingKeys: String, CodingKey {
        case bookID = "book_id"
        case title
        case pageCount = "page_count"
        case wordCountEstimate = "word_count_estimate"
        case estimatedProcessingSeconds = "estimated_processing_seconds"
        case estimatedAudioSeconds = "estimated_audio_seconds"
        case estimatedCostUsd = "estimated_cost_usd"
        case estimatedTokenCount = "estimated_token_count"
        case isImageOnly = "is_image_only"
        case costWarning = "cost_warning"
    }
}

enum ProcessingStatus: Hashable {
    case queued
    case extracting(page: Int, total: Int)
    case cleaning(page: Int, total: Int)
    case generating(page: Int, total: Int)
    case ready
    case needsKey
    case failed(reason: String)
    case cancelled

    var isProcessing: Bool {
        switch self {
        case .extracting, .cleaning, .generating, .queued: return true
        default: return false
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var caption: String {
        switch self {
        case .queued: return "QUEUED"
        case .extracting(let p, let t): return "EXTRACTING \(p)/\(t)"
        case .cleaning(let p, let t): return "CLEANING \(p)/\(t)"
        case .generating(let p, let t): return "GENERATING \(p)/\(t)"
        case .ready: return "READY"
        case .needsKey: return "NEEDS KEY — RESUME"
        case .failed: return "FAILED — TAP TO RETRY"
        case .cancelled: return "CANCELLED — CLICK TO RESTART"
        }
    }
}

/// Format a duration into "1h 24m" / "12m 5s" / "45s".
enum DurationFormatter {
    static func short(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
