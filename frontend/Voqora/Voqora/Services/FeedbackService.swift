import Foundation

enum FeedbackKind: String, CaseIterable, Identifiable {
    case issue, idea, hello

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .issue: "Something broke"
        case .idea: "I have an idea"
        case .hello: "Just saying hi"
        }
    }

    var subtitle: String {
        switch self {
        case .issue: "Tell me what went wrong"
        case .idea: "Big or small"
        case .hello: "Praise, questions, anything"
        }
    }

    var icon: String {
        switch self {
        case .issue: "ant"
        case .idea: "sparkles"
        case .hello: "hand.wave"
        }
    }

    var placeholder: String {
        switch self {
        case .issue: "What were you doing, and what happened instead?"
        case .idea: "What would you like Voqora to do?"
        case .hello: "Say anything."
        }
    }
}

struct FeedbackService {
    static let endpoint = URL(string: "https://himudigonda.me/api/voqora/feedback")!
    static let maxLength = 5000
    static let emailPattern = /^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,24}$/

    enum SendError: LocalizedError, Equatable {
        case empty
        case tooLong
        case invalidEmail
        case rateLimited
        case rejected
        case failed

        var errorDescription: String? {
            switch self {
            case .empty: "Write a few words first."
            case .tooLong: "Keep it under \(FeedbackService.maxLength) characters."
            case .invalidEmail: "That email doesn't look right."
            case .rateLimited: "That's a lot at once. Try again in a few minutes."
            case .rejected: "That didn't go through. Try shortening or rewording it."
            case .failed: "Couldn't send. Check your connection and try again."
            }
        }
    }

    var anonID: () -> String
    var sendRequest: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    var osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    func send(kind: FeedbackKind, message: String, email: String, includeVersions: Bool) async throws {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        let contact = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { throw SendError.empty }
        guard text.utf16.count <= Self.maxLength else { throw SendError.tooLong }
        guard contact.isEmpty || (contact.count <= 254 && contact.wholeMatch(of: Self.emailPattern) != nil) else {
            throw SendError.invalidEmail
        }

        var body: [String: Any] = ["anon_id": anonID(), "kind": kind.rawValue, "message": text]
        if !contact.isEmpty {
            body["email"] = contact
        }
        if includeVersions {
            body["app_version"] = appVersion
            body["os_version"] = osVersion
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let response: URLResponse
        do {
            response = try await sendRequest(request).1
        } catch {
            throw SendError.failed
        }
        switch (response as? HTTPURLResponse)?.statusCode {
        case .some(200 ..< 300): return
        case 429: throw SendError.rateLimited
        case .some(400 ..< 500): throw SendError.rejected
        default: throw SendError.failed
        }
    }
}
