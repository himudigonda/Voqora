import Foundation

nonisolated enum AudiobookImportSource: Hashable, Sendable {
    case document(URL)
    case webPage(URL)

    var documentURL: URL? {
        guard case let .document(url) = self else { return nil }
        return url
    }

    var webPageURL: URL? {
        guard case let .webPage(url) = self else { return nil }
        return url
    }

    var identifier: String {
        switch self {
        case let .document(url): "document-\(url.absoluteString)"
        case let .webPage(url): "web-\(url.absoluteString)"
        }
    }

    var displayName: String {
        switch self {
        case let .document(url):
            AudiobookImportStaging.displayName(from: url.lastPathComponent)
        case let .webPage(url):
            WebPageLink.siteName(of: url)
        }
    }
}

nonisolated enum WebPageLink {
    static let maximumLength = 2048
    static let allowedSchemes: Set<String> = ["http", "https"]

    enum Problem: Error, Equatable, Sendable {
        case empty
        case notWebLink
        case containsCredentials
        case tooLong

        var message: String {
            switch self {
            case .empty: "Enter the address of a web page."
            case .notWebLink: "Enter a link that starts with http:// or https://."
            case .containsCredentials: "Remove the user name and password from the link."
            case .tooLong: "This link is too long. Use a link under 2,048 characters."
            }
        }
    }

    static func validate(_ input: String) -> Result<URL, Problem> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard !trimmed.contains(where: \.isWhitespace) else { return .failure(.notWebLink) }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard candidate.count <= maximumLength else { return .failure(.tooLong) }
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              allowedSchemes.contains(scheme),
              let host = components.host,
              !host.isEmpty
        else { return .failure(.notWebLink) }
        guard components.user == nil, components.password == nil else { return .failure(.containsCredentials) }
        guard let url = components.url, url.absoluteString.count <= maximumLength else { return .failure(.tooLong) }
        return .success(url)
    }

    static func siteName(of url: URL) -> String {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

nonisolated struct WebPageImportBody: Encodable, Equatable, Sendable {
    let url: String
    let voice: String?
    let speed: Double?
    let engine: String?
    let pauseScale: Double?
    let llmProvider: String?
    let llmModel: String?
    let llmBaseURL: String?

    init(url: URL, voice: String?, speed: Double?, engine: String?, pauseScale: Double? = nil, cleanup: LLMCredential?) {
        self.url = url.absoluteString
        self.voice = voice
        self.speed = speed
        self.engine = engine
        self.pauseScale = pauseScale.map(PauseScale.clamped)
        llmProvider = cleanup?.provider.rawValue
        llmModel = cleanup?.resolvedModel
        if let cleanup, cleanup.provider.acceptsServerURL, !cleanup.serverURL.isEmpty {
            llmBaseURL = cleanup.serverURL
        } else {
            llmBaseURL = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case url, voice, speed, engine
        case pauseScale = "pause_scale"
        case llmProvider = "llm_provider"
        case llmModel = "llm_model"
        case llmBaseURL = "llm_base_url"
    }
}

nonisolated enum WebPageImportMessage {
    static let generic = "Couldn't add this page. Please try again."
    static let timeoutMessage = "The site took too long to respond. Try again in a moment."

    static func message(for error: Error) -> String {
        if let failure = error as? AudiobookAPIFailure {
            return message(for: failure)
        }
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? timeoutMessage : generic
        }
        if let problem = error as? WebPageLink.Problem {
            return problem.message
        }
        return (error as? LocalizedError)?.errorDescription ?? generic
    }

    static func message(for failure: AudiobookAPIFailure) -> String {
        if let code = failure.code, let message = codeMessages[code] {
            return message
        }
        if failure.statusCode == 422, failure.detail == nil {
            return "Check the link and the narration settings, then try again."
        }
        return failure.detail ?? generic
    }

    static let codeMessages: [String: String] = [
        "invalid_url": WebPageLink.Problem.notWebLink.message,
        "blocked_address": "Voqora doesn't open links to this Mac or to private network addresses.",
        "too_large": "This page is too large to turn into an audiobook.",
        "timeout": timeoutMessage,
        "no_readable_content": "Voqora couldn't find readable text on this page.",
        "unsupported_type": "This link isn't a web page or PDF that Voqora can read.",
        "pdf_document": "This link isn't a web page or PDF that Voqora can read.",
        "paywalled": "This page needs a subscription or sign-in. Save it from your browser as a web page and import the file instead.",
        "unreachable": "Voqora couldn't reach this site. Check the link and your internet connection.",
        "not_found": "The site says this page doesn't exist. Check the link.",
        "http_error": "The site didn't return this page. Try again later.",
        "too_many_redirects": "This link redirects too many times to follow.",
        "busy": "Voqora is already fetching several pages. Try again in a moment.",
    ]
}
