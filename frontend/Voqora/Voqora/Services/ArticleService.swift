import Foundation

nonisolated struct ExtractedArticle: Decodable, Equatable, Sendable {
    let url: URL
    let title: String
    let byline: String?
    let siteName: String?
    let language: String?
    let text: String
    let markdown: String
    let wordCount: Int

    enum CodingKeys: String, CodingKey {
        case url
        case title
        case byline
        case siteName = "site_name"
        case language
        case text
        case markdown
        case wordCount = "word_count"
    }
}

nonisolated struct AudiobookNarration: Equatable, Sendable {
    static let speedRange = 0.5 ... 2.0

    let voice: String
    let speed: Double

    var engine: String {
        SpeechEngineID.engine(forVoice: voice)
    }

    init(voice: String, speed: Double) {
        self.voice = voice
        self.speed = speed.isFinite ? min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound) : 1.0
    }
}

nonisolated struct ArticleServiceError: LocalizedError, Equatable, Sendable {
    nonisolated enum Reason: String, Equatable, Sendable {
        case engineUnavailable
        case invalidURL = "invalid_url"
        case blockedAddress = "blocked_address"
        case unreachable
        case timeout
        case tooManyRedirects = "too_many_redirects"
        case httpError = "http_error"
        case notFound = "not_found"
        case paywalled
        case unsupportedType = "unsupported_type"
        case pdfDocument = "pdf_document"
        case tooLarge = "too_large"
        case noReadableContent = "no_readable_content"
        case busy
        case rejected
        case invalidResponse

        var isBackendCode: Bool {
            switch self {
            case .engineUnavailable, .rejected, .invalidResponse: false
            default: true
            }
        }
    }

    let reason: Reason
    let detail: String?

    init(_ reason: Reason, detail: String? = nil) {
        self.reason = reason
        self.detail = detail
    }

    var errorDescription: String? {
        switch reason {
        case .engineUnavailable: "Voqora is still starting. Try again in a moment."
        case .invalidURL: "That link doesn't look right. Use a full web address that starts with http or https."
        case .blockedAddress: "Voqora only reads public web pages. Links to this Mac or your local network aren't supported."
        case .unreachable: "Voqora couldn't reach that site. Check the link and your internet connection."
        case .timeout: "That site took too long to respond. Try again later."
        case .tooManyRedirects: "That link redirects too many times for Voqora to follow."
        case .httpError: "That site returned an error. Try again later."
        case .notFound: "That page no longer exists. Check the link and try again."
        case .paywalled: "That article is behind a paywall or sign-in, so Voqora can't read it."
        case .unsupportedType: "That link isn't a web article Voqora can read."
        case .pdfDocument: "That link is a PDF. Make it an audiobook instead."
        case .tooLarge: "That page is too large for Voqora to read."
        case .noReadableContent: "Voqora couldn't find an article on that page."
        case .busy: "Voqora is reading several pages already. Try again in a moment."
        case .rejected: detail ?? "Voqora couldn't add that page. Try again."
        case .invalidResponse: "Voqora received an unexpected reply from its engine. Try again."
        }
    }
}

final class ArticleService {
    nonisolated static let extractTimeout: TimeInterval = 40
    nonisolated static let audiobookTimeout: TimeInterval = 90

    private let connection: BackendConnection
    private let session: URLSession

    init(connection: BackendConnection? = nil, session: URLSession? = nil) {
        self.connection = connection ?? .shared
        self.session = session ?? .shared
    }

    private nonisolated struct ExtractRequest: Encodable {
        let url: String
    }

    private nonisolated struct AudiobookRequest: Encodable {
        let url: String
        let voice: String
        let speed: Double
        let engine: String
    }

    private nonisolated struct ErrorBody: Decodable {
        let detail: String?
        let code: String?

        enum CodingKeys: String, CodingKey {
            case detail
            case code
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            detail = try? container.decode(String.self, forKey: .detail)
            code = try? container.decode(String.self, forKey: .code)
        }
    }

    func extract(_ url: URL) async throws -> ExtractedArticle {
        let data = try await post(
            path: "article/extract",
            body: ExtractRequest(url: url.absoluteString),
            timeout: Self.extractTimeout
        )
        do {
            return try JSONDecoder().decode(ExtractedArticle.self, from: data)
        } catch {
            throw ArticleServiceError(.invalidResponse)
        }
    }

    func createAudiobook(from url: URL, narration: AudiobookNarration) async throws -> AudiobookEstimateResponse {
        let data = try await post(
            path: "audiobook/url",
            body: AudiobookRequest(
                url: url.absoluteString,
                voice: narration.voice,
                speed: narration.speed,
                engine: narration.engine
            ),
            timeout: Self.audiobookTimeout
        )
        do {
            return try JSONDecoder().decode(AudiobookEstimateResponse.self, from: data)
        } catch {
            throw ArticleServiceError(.invalidResponse)
        }
    }

    private func post(path: String, body: some Encodable, timeout: TimeInterval) async throws -> Data {
        var request: URLRequest
        do {
            request = try connection.request(path: path, method: "POST", timeout: timeout)
        } catch {
            throw ArticleServiceError(.engineUnavailable)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw ArticleServiceError(.timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ArticleServiceError(.engineUnavailable)
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else {
            throw ArticleServiceError(.invalidResponse)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw Self.failure(status: http.statusCode, data: data)
        }
        return data
    }

    nonisolated static func failure(status: Int, data: Data) -> ArticleServiceError {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        let detail = body?.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableDetail = detail?.isEmpty == false ? detail : nil
        if let code = body?.code, let reason = ArticleServiceError.Reason(rawValue: code), reason.isBackendCode {
            return ArticleServiceError(reason, detail: usableDetail)
        }
        if let usableDetail {
            return ArticleServiceError(.rejected, detail: usableDetail)
        }
        switch status {
        case 422: return ArticleServiceError(.invalidURL)
        case 429: return ArticleServiceError(.busy)
        case 503: return ArticleServiceError(.engineUnavailable)
        default: return ArticleServiceError(.rejected)
        }
    }
}
