import Combine
import Foundation
import OSLog

/// Lightweight identity owner for Voqora analytics.
///
/// There is no sign-in. The only persistent identity is:
///   1. An anonymous UUID stored in UserDefaults under `anonymousUserID`
///      (created on first launch and stable for that installation; sent only
///      with optional product telemetry or an explicitly submitted email).
///   2. An optional email address the user enters during onboarding (or in
///      Preferences). The email is POSTed to `/api/voqora/identify` so
///      analytics can group return-visits by email instead of by UUID.
///
/// Nothing about the app is gated on whether the user provided an email —
/// this is identity for telemetry attribution only.
@MainActor
final class IdentityService: ObservableObject {
    static let shared = IdentityService()

    private static let log = Logger(subsystem: "me.himudigonda.Voqora", category: "identity")
    private static let endpoint = URL(string: "https://himudigonda.me/api/voqora/identify")!
    private static let anonKey = "anonymousUserID"
    private static let emailKey = "userIdentityEmail"

    /// Current email if the user provided one. `nil` means anonymous.
    @Published private(set) var email: String?

    /// Stable per-install UUID used as `anon_id` server-side. Read once
    /// at init and cached; never changes for the lifetime of an install.
    let anonID: String

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: Self.anonKey), !stored.isEmpty {
            self.anonID = stored
        } else {
            let fresh = UUID().uuidString
            defaults.set(fresh, forKey: Self.anonKey)
            self.anonID = fresh
        }
        self.email = defaults.string(forKey: Self.emailKey)
    }

    /// `true` if the user submitted an email during onboarding or in Preferences.
    var hasIdentity: Bool { email?.isEmpty == false }

    /// Submit an email to the backend. On success, persist locally.
    /// Throws `IdentityError` if the email is malformed or the request fails.
    func submitEmail(_ raw: String) async throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.looksLikeEmail(trimmed) else {
            throw IdentityError.invalidEmail
        }
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let body: [String: Any] = [
            "anon_id": anonID,
            "email": trimmed,
            "app_version": appVersion,
            "platform": "macOS",
        ]

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            Self.log.error("identify network failure: \(error.localizedDescription, privacy: .public)")
            throw IdentityError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw IdentityError.server("non-HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            let snippet = String(data: data.prefix(256), encoding: .utf8) ?? ""
            Self.log.error("identify status=\(http.statusCode, privacy: .public) body=\(snippet, privacy: .public)")
            throw IdentityError.server("Server error \(http.statusCode)")
        }

        defaults.set(trimmed, forKey: Self.emailKey)
        self.email = trimmed
        Self.log.info("identify ok for anon=\(self.anonID.prefix(8), privacy: .public)")
    }

    /// Clear the local email only. Primarily useful for tests and recovery;
    /// normal product UI calls `removeEmail()` so the optional server-side
    /// contact is removed too.
    func clearEmail() {
        defaults.removeObject(forKey: Self.emailKey)
        email = nil
    }

    /// Remove the optional contact from the product backend and this Mac.
    /// The anonymous event history remains anonymous activity history; it is
    /// not an identity record and is never rewritten into a person count.
    func removeEmail() async throws {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["anon_id": anonID])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IdentityError.server("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(256), encoding: .utf8) ?? ""
            Self.log.error("identity delete status=\(http.statusCode, privacy: .public) body=\(snippet, privacy: .public)")
            throw IdentityError.server("Server error \(http.statusCode)")
        }
        clearEmail()
    }

    static func looksLikeEmail(_ s: String) -> Bool {
        guard s.count >= 3, s.count <= 254 else { return false }
        let parts = s.split(separator: "@")
        guard parts.count == 2 else { return false }
        let local = parts[0], domain = parts[1]
        if local.isEmpty || domain.isEmpty { return false }
        if !domain.contains(".") { return false }
        return !s.contains(" ")
    }

    enum IdentityError: LocalizedError {
        case invalidEmail
        case network(String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .invalidEmail: return "Please enter a valid email address."
            case .network(let m): return "Network error: \(m)"
            case .server(let m): return m
            }
        }
    }
}
