import Combine
import Foundation
import OSLog

/// Identity owner for Voqora analytics. Name and email are required during
/// onboarding before the app can be used, and are POSTed to
/// `/api/voqora/identify` alongside the stable per-install `anon_id`.
@MainActor
final class IdentityService: ObservableObject {
    static let shared = IdentityService()

    private static let log = Logger(subsystem: "me.himudigonda.Voqora", category: "identity")
    private static let endpoint = URL(string: "https://himudigonda.me/api/voqora/identify")!
    private static let anonKey = "anonymousUserID"
    private static let emailKey = "userIdentityEmail"
    private static let nameKey = "userIdentityName"
    private static let pendingRemovalKey = "userIdentityRemovalPending"
    private static let pendingSubmissionKey = "userIdentitySubmissionPending"

    @Published private(set) var email: String?
    @Published private(set) var name: String?
    /// Retained for installs that queued an email removal before identity
    /// became mandatory; there is no current UI path that sets this again.
    @Published private(set) var hasPendingRemoval: Bool
    /// True from the moment `submitIdentity` persists locally until the
    /// backend confirms receipt. Onboarding never waits on this — it only
    /// gates on `hasIdentity`, which flips true immediately.
    @Published private(set) var hasPendingSubmission: Bool

    private var storedAnonID: String?
    var anonID: String {
        if let storedAnonID, !storedAnonID.isEmpty {
            return storedAnonID
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: Self.anonKey)
        storedAnonID = fresh
        return fresh
    }

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
        storedAnonID = defaults.string(forKey: Self.anonKey)
        email = defaults.string(forKey: Self.emailKey)
        name = defaults.string(forKey: Self.nameKey)
        hasPendingRemoval = defaults.bool(forKey: Self.pendingRemovalKey)
        hasPendingSubmission = defaults.bool(forKey: Self.pendingSubmissionKey)
    }

    var hasIdentity: Bool {
        email?.isEmpty == false && name?.isEmpty == false
    }

    /// Validates, then persists locally and returns immediately — delivery to
    /// the backend never blocks the caller or onboarding. A failed or offline
    /// send is queued and retried by `retryPendingSubmission`, the same
    /// pattern `retryPendingRemoval` already uses for email removal.
    func submitIdentity(name rawName: String, email rawEmail: String) async throws {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.looksLikeName(trimmedName) else {
            throw IdentityError.invalidName
        }
        guard Self.looksLikeEmail(trimmedEmail) else {
            throw IdentityError.invalidEmail
        }

        defaults.set(trimmedName, forKey: Self.nameKey)
        defaults.set(trimmedEmail, forKey: Self.emailKey)
        defaults.set(true, forKey: Self.pendingSubmissionKey)
        name = trimmedName
        email = trimmedEmail
        hasPendingSubmission = true

        Task { await self.retryPendingSubmission() }
    }

    /// Sends the locally saved name/email to the backend if a send is still
    /// pending. Quiet on failure — an unavailable identity endpoint must
    /// never interrupt onboarding or reading, so this is safe to call from
    /// launch, from `submitIdentity`, or on a future retry timer.
    @discardableResult
    func retryPendingSubmission() async -> Bool {
        guard hasPendingSubmission, let name, let email else { return true }
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let body: [String: Any] = [
            "anon_id": anonID,
            "name": name,
            "email": email,
            "app_version": appVersion,
            "platform": "macOS",
        ]
        guard let requestBody = try? JSONSerialization.data(withJSONObject: body) else {
            return false
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = requestBody

        let response: URLResponse
        do {
            response = try await sendRequest(req).1
        } catch {
            Self.log.error("identify network failure")
            return false
        }
        guard let http = response as? HTTPURLResponse else {
            return false
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            Self.log.error("identify status=\(http.statusCode, privacy: .public)")
            return false
        }

        defaults.removeObject(forKey: Self.pendingSubmissionKey)
        hasPendingSubmission = false
        Self.log.info("identity saved")
        return true
    }

    func clearEmail() {
        defaults.removeObject(forKey: Self.emailKey)
        email = nil
    }

    func eraseLocalIdentity() {
        defaults.removeObject(forKey: Self.emailKey)
        defaults.removeObject(forKey: Self.nameKey)
        defaults.removeObject(forKey: Self.anonKey)
        defaults.removeObject(forKey: Self.pendingRemovalKey)
        defaults.removeObject(forKey: Self.pendingSubmissionKey)
        storedAnonID = nil
        email = nil
        name = nil
        hasPendingRemoval = false
        hasPendingSubmission = false
    }

    enum RemovalResult: Equatable {
        case removedRemotely
        case queuedForRetry
    }

    /// No product UI calls this any more — identity is mandatory. Kept for
    /// the legacy erasure primitive it is: clears the local email first, then
    /// attempts the independent remote-contact removal.
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
        guard (200 ..< 300).contains(http.statusCode) else {
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

    static func looksLikeName(_ s: String) -> Bool {
        (1 ... 120).contains(s.count)
    }

    enum IdentityError: LocalizedError, Equatable {
        case invalidName
        case invalidEmail

        var errorDescription: String? {
            switch self {
            case .invalidName: "Please enter your name."
            case .invalidEmail: "Please enter a valid email address."
            }
        }
    }
}
