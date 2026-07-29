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

    var id: String {
        bookID
    }

    var progressFraction: Double {
        let total = Double(phaseProgress.pageTotal)
        guard total > 0 else { return 0 }
        return Double(phaseProgress.pageDone) / total
    }

    var displayStatus: ProcessingStatus {
        switch status {
        case "ready", "queued": .queued
        case "extracting":
            .extracting(page: phaseProgress.pageDone, total: phaseProgress.pageTotal)
        case "cleaning":
            .cleaning(page: phaseProgress.pageDone, total: phaseProgress.pageTotal)
        case "sectioning":
            .sectioning
        case "tts":
            .generating(page: phaseProgress.pageDone, total: phaseProgress.pageTotal)
        case "concatenating":
            .generating(page: phaseProgress.pageTotal, total: phaseProgress.pageTotal)
        case "done":
            .ready
        case "needs_key":
            .needsKey
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
    var id: String {
        "\(startPage)-\(endPage)"
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
    /// Backend is running real chapter/heading detection (PDF outline / DOCX
    /// heading styles / Markdown headers / Gemini fallback — the v1.1 design notes §5.2,
    /// `_phase_section`). Monolithic and non-paginated like `.queued` — the
    /// backend never emits per-item progress for it — but held from
    /// `phase_started` to `phase_finished`, which is a real, non-instant
    /// duration for large documents (D5). Kept distinct from `.queued` so
    /// the UI doesn't regress to "QUEUED" for that whole window.
    case sectioning
    case generating(page: Int, total: Int)
    /// The SSE connection has failed to reconnect N times in a row (the v1.1 design notes
    /// Sprint 7, T7.10/E11). The book is very likely still processing
    /// server-side — we just can't confirm live progress right now — so this
    /// stays `isProcessing == true`. Cleared automatically the next time any
    /// real event flows through (a fresh snapshot on reconnect, or the next
    /// phase/page event), never needs an explicit "recovered" transition.
    case reconnecting
    case ready
    case needsKey
    case failed(reason: String)
    case cancelled

    var isProcessing: Bool {
        switch self {
        case .extracting, .cleaning, .sectioning, .generating, .queued, .reconnecting: true
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
        case .queued: "QUEUED"
        case let .extracting(p, t): "EXTRACTING \(p)/\(t)"
        case let .cleaning(p, t): "CLEANING \(p)/\(t)"
        case .sectioning: "DETECTING CHAPTERS"
        case let .generating(p, t): "GENERATING \(p)/\(t)"
        case .reconnecting: "RECONNECTING…"
        case .ready: "READY"
        case .needsKey: "NEEDS KEY — RESUME"
        case .failed: "FAILED — TAP TO RETRY"
        case .cancelled: "CANCELLED — CLICK TO RESTART"
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
        if h > 0 {
            return "\(h)h \(m)m"
        }
        if m > 0 {
            return "\(m)m \(s)s"
        }
        return "\(s)s"
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
