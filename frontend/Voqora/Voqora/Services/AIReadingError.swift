import Foundation

nonisolated struct AIReadingError: LocalizedError, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case providerRequired
        case providerSettings
        case busy
        case tooLarge
        case bookUnavailable
        case noText
        case provider
        case timeout
        case invalidRequest
        case engineUnavailable
        case invalidResponse
        case failed
    }

    let kind: Kind
    let message: String
    let code: String?

    init(kind: Kind, message: String, code: String? = nil) {
        self.kind = kind
        self.message = message
        self.code = code
    }

    var errorDescription: String? {
        message
    }

    var isRetryable: Bool {
        switch kind {
        case .busy, .timeout, .engineUnavailable, .provider, .invalidResponse, .failed: true
        case .providerRequired, .providerSettings, .tooLarge, .bookUnavailable, .noText, .invalidRequest: false
        }
    }

    static let providerRequired = AIReadingError(
        kind: .providerRequired,
        message: "Connect an AI provider in Settings > AI to use AI reading tools.",
        code: "ai_provider_required"
    )

    static let engineUnavailable = AIReadingError(
        kind: .engineUnavailable,
        message: "Voqora's engine isn't running. Try again in a moment."
    )

    static let invalidResponse = AIReadingError(
        kind: .invalidResponse,
        message: "Voqora could not read the AI response. Try again."
    )

    static func emptyInput(_ message: String) -> AIReadingError {
        AIReadingError(kind: .noText, message: message)
    }

    static func tooLong(_ message: String) -> AIReadingError {
        AIReadingError(kind: .tooLarge, message: message)
    }

    static func wrapping(_ error: Error) -> AIReadingError {
        if let error = error as? AIReadingError {
            return error
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return AIReadingError(kind: .timeout, message: "The AI request took too long. Try again.")
        }
        if error is URLError || error is BackendConnection.ConnectionError {
            return .engineUnavailable
        }
        if error is DecodingError {
            return .invalidResponse
        }
        return AIReadingError(kind: .failed, message: "The AI request failed. Try again.")
    }
}

nonisolated enum AIReadingErrorMapper {
    static func error(statusCode: Int, data: Data) -> AIReadingError {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let detail = (body?["detail"] as? String).flatMap { $0.isEmpty ? nil : preferencesWording($0) }
        let code = body?["code"] as? String
        if let code {
            return error(code: code, detail: detail)
        }
        return error(statusCode: statusCode, detail: detail)
    }

    private static func error(code: String, detail: String?) -> AIReadingError {
        func make(_ kind: AIReadingError.Kind, _ fallback: String) -> AIReadingError {
            AIReadingError(kind: kind, message: detail ?? fallback, code: code)
        }
        switch code {
        case "ai_provider_required":
            guard let detail, !detail.hasPrefix(missingProviderPrefix) else { return .providerRequired }
            return make(.providerSettings, detail)
        case "llm_config_failed":
            return make(.providerSettings, "Check your AI provider in Settings > AI.")
        case "ai_busy":
            return make(.busy, "Voqora is already working on other AI requests. Try again shortly.")
        case "ai_rate_limited":
            return make(.busy, "Too many AI requests in the last minute. Try again shortly.")
        case "llm_busy":
            return make(.busy, "Your AI provider is busy. Try again shortly.")
        case "book_too_long":
            return make(.tooLarge, "This book is too long for AI tools.")
        case "text_too_long":
            return make(.tooLarge, "This text is too long for one AI request. Try a shorter passage.")
        case "ai_budget_exceeded":
            return make(.tooLarge, "This request is larger than Voqora's AI limit for one request. Try a shorter text.")
        case "book_not_found":
            return make(.bookUnavailable, "This book is no longer in your library.")
        case "book_text_unavailable":
            return make(.bookUnavailable, "This book's text isn't ready yet. Try again after it finishes importing.")
        case "no_text":
            return make(.noText, "There is no text to work with.")
        case "ai_timeout":
            return make(.timeout, "The AI request took too long. Try again.")
        case "ai_invalid_output":
            return make(.invalidResponse, "Your AI provider returned an answer Voqora could not read. Try again.")
        case let providerCode where providerCode.hasPrefix("llm_"):
            return make(.provider, "Your AI provider could not finish the request. Try again.")
        default:
            return make(.failed, "The AI request failed. Try again.")
        }
    }

    private static let missingProviderPrefix = "Choose an AI provider"

    private static func preferencesWording(_ detail: String) -> String {
        detail.replacingOccurrences(of: " in Settings", with: " in Settings > AI")
    }

    private static func error(statusCode: Int, detail: String?) -> AIReadingError {
        switch statusCode {
        case 400:
            AIReadingError(kind: .providerSettings, message: detail ?? "Check your AI provider in Settings > AI.")
        case 401, 403:
            .engineUnavailable
        case 413:
            AIReadingError(kind: .tooLarge, message: detail ?? "This text is too long for one AI request. Try a shorter passage.")
        case 422:
            AIReadingError(kind: .invalidRequest, message: "Voqora could not send that request. Check the text and try again.")
        case 429:
            AIReadingError(kind: .busy, message: detail ?? "Voqora is already working on other AI requests. Try again shortly.")
        case 504:
            AIReadingError(kind: .timeout, message: detail ?? "The AI request took too long. Try again.")
        default:
            AIReadingError(kind: .failed, message: detail ?? "The AI request failed. Try again.")
        }
    }
}
