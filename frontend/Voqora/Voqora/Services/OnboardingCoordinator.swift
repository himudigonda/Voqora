import Combine
import Foundation
import ApplicationServices

/// Single source of truth for first-launch onboarding state.
///
/// Before v1.1 the `hasOnboarded` flag was checked ad hoc in `VoqoraApp.init`
/// and surrounding views. This coordinator centralizes the read/write/reset
/// surface and is the only thing views should consult.
@MainActor
final class OnboardingCoordinator: ObservableObject {
    /// Bump when onboarding flow changes shape; existing users see it again once.
    /// v3 includes the permission-led flow and private voice/language
    /// personalization step.
    private static let currentVersion = 3

    @Published private(set) var version: Int = 0
    private let accessibilityTrusted: () -> Bool
    private let defaults: UserDefaults

    private var hasOnboarded: Bool {
        get { defaults.bool(forKey: "hasOnboarded") }
        set { defaults.set(newValue, forKey: "hasOnboarded") }
    }

    private var storedVersion: Int {
        get { defaults.integer(forKey: "onboardingVersion") }
        set { defaults.set(newValue, forKey: "onboardingVersion") }
    }

    init(
        accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        defaults: UserDefaults = .standard
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.defaults = defaults
        if storedVersion < Self.currentVersion {
            hasOnboarded = false
            storedVersion = Self.currentVersion
        }
    }

    /// Onboarding must run when it was never completed, OR when the core
    /// Accessibility grant is missing. The latter is the key case: a reinstall
    /// re-signs the app, so macOS revokes the Accessibility grant tied to the old
    /// signature, and a returning user would otherwise land in an app whose global
    /// hotkey silently can't read selected text. Onboarding is where we (re)request
    /// that permission, so re-run it until the app can actually function.
    ///
    var needsOnboarding: Bool { !hasOnboarded || !accessibilityTrusted() }

    func markCompleted() {
        hasOnboarded = true
        storedVersion = Self.currentVersion
        version &+= 1
    }

    func reset() {
        hasOnboarded = false
        version &+= 1
    }
}
