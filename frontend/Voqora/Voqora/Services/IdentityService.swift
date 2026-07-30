import Combine
import Foundation
import OSLog

/// Lightweight identity owner for Voqora analytics.
///
/// Replaces the v1 auth stack (Supabase JWT, Google OAuth, email/password).
/// There is no real "sign-in" — the only persistent identity is:
///   1. An anonymous UUID stored in UserDefaults under `anonymousUserID`
///      (created on first launch, never rotates, never leaves the device).
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
    // No "www." — that host 308-redirects to the bare domain, and URLSession's
    // default redirect handling drops the POST body on follow, so the request
    // arrives at the destination with no anon_id (server then 400s).
    private static let endpoint = URL(string: "https://himudigonda.me/api/voqora/identify")!
    private static let anonKey = "anonymousUserID"
    private static let emailKey = "userIdentityEmail"
    private static let pendingRemovalKey = "userIdentityRemovalPending"

    /// Current email if the user provided one. `nil` means anonymous.
    @Published private(set) var email: String?
    /// A user may remove their optional email while offline. Their Mac must
    /// honour that request immediately, while this marker lets the app retry
    /// deleting the separate remote contact when a connection is available.
    @Published private(set) var hasPendingRemoval: Bool

    /// Stable per-install UUID used as `anon_id` server-side. Read once
    /// at init and cached; never changes for the lifetime of an install.
    let anonID: String
    private let defaults: UserDefaults
    private let sendRequest: (URLRequest) async throws -> (Data, URLResponse)

    init(
        defaults: UserDefaults = .standard,
        sendRequest: @escaping (URLRequest) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(for: $0)
        }
    ) {
        self.defaults = defaults
        self.sendRequest = sendRequest
        if let stored = defaults.string(forKey: Self.anonKey), !stored.isEmpty {
            anonID = stored
        } else {
            let fresh = UUID().uuidString
            defaults.set(fresh, forKey: Self.anonKey)
            anonID = fresh
        }
        self.email = defaults.string(forKey: Self.emailKey)
        self.hasPendingRemoval = defaults.bool(forKey: Self.pendingRemovalKey)
    }

    /// `true` if the user submitted an email during onboarding or in Preferences.
    var hasIdentity: Bool {
        email?.isEmpty == false
    }

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

        let response: URLResponse
        do {
            response = try await sendRequest(req).1
        } catch {
            Self.log.error("identify network failure: \(error.localizedDescription, privacy: .public)")
            throw IdentityError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw IdentityError.server("non-HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            Self.log.error("identify status=\(http.statusCode, privacy: .public)")
            throw IdentityError.server("Server error \(http.statusCode)")
        }

        defaults.set(trimmed, forKey: Self.emailKey)
        defaults.removeObject(forKey: Self.pendingRemovalKey)
        self.email = trimmed
        hasPendingRemoval = false
        Self.log.info("optional identity saved")
    }

    /// Clear the local email only. The product UI calls `removeEmail()` so a
    /// user can remove their optional contact from both sides deliberately.
    func clearEmail() {
        defaults.removeObject(forKey: Self.emailKey)
        email = nil
    }

    enum RemovalResult: Equatable {
        case removedRemotely
        case queuedForRetry
    }

    /// Remove the optional email from this Mac first, then attempt the
    /// independent remote-contact removal. A failed network request cannot
    /// force someone to retain their local email. The anonymous event history
    /// remains anonymous activity history; it is not rewritten into a person
    /// count.
    func removeEmail() async -> RemovalResult {
        clearEmail()
        defaults.set(true, forKey: Self.pendingRemovalKey)
        hasPendingRemoval = true
        return await retryPendingRemoval() ? .removedRemotely : .queuedForRetry
    }

    /// Retry a previously requested remote-contact removal. This is quiet on
    /// startup because an unavailable analytics endpoint must never interrupt
    /// reading or onboarding.
    @discardableResult
    func retryPendingRemoval() async -> Bool {
        guard hasPendingRemoval else { return true }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let requestBody = try? JSONSerialization.data(withJSONObject: ["anon_id": anonID]) else {
            return false
        }
        request.httpBody = requestBody

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await sendRequest(request)
        } catch {
            return false
        }
        guard let http = response as? HTTPURLResponse else {
            return false
        }
        guard (200..<300).contains(http.statusCode) else {
            _ = responseData
            Self.log.error("identity delete status=\(http.statusCode, privacy: .public)")
            return false
        }
        defaults.removeObject(forKey: Self.pendingRemovalKey)
        hasPendingRemoval = false
        return true
    }

    static func looksLikeEmail(_ s: String) -> Bool {
        guard s.count >= 3, s.count <= 254 else { return false }
        let parts = s.split(separator: "@")
        guard parts.count == 2 else { return false }
        let local = parts[0], domain = parts[1]
        if local.isEmpty || domain.isEmpty {
            return false
        }
        if !domain.contains(".") {
            return false
        }
        return !s.contains(" ")
    }

    enum IdentityError: LocalizedError {
        case invalidEmail
        case network(String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .invalidEmail: "Please enter a valid email address."
            case let .network(m): "Network error: \(m)"
            case let .server(m): m
            }
        }
    }
}
