import Combine
import Foundation

/// Single source of truth for first-launch onboarding state.
///
/// Before the repaired public Voqora flow, the `hasOnboarded` flag was checked ad hoc in `VoqoraApp.init`
/// and surrounding views. This coordinator centralizes the read/write/reset
/// surface and is the only thing views should consult.
@MainActor
final class OnboardingCoordinator: ObservableObject {
    /// Bump when onboarding flow changes shape; existing users see it again once.
    /// v3: re-ran the permission-led first-use flow for the public Voqora
    /// release after the legacy identity change.
    /// v4: re-runs the repaired flow once for profiles created by the early
    /// public builds, which could carry a completed flag while opening into a
    /// non-functional player. It never resets user content or preferences.
    private static let currentVersion = 4

    @Published private(set) var version: Int = 0
    private let defaults: UserDefaults

    private var hasOnboarded: Bool {
        get { defaults.bool(forKey: "hasOnboarded") }
        set { defaults.set(newValue, forKey: "hasOnboarded") }
    }

    private var storedVersion: Int {
        get { defaults.integer(forKey: "onboardingVersion") }
        set { defaults.set(newValue, forKey: "onboardingVersion") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if storedVersion < Self.currentVersion {
            hasOnboarded = false
            storedVersion = Self.currentVersion
        }
    }

    /// Accessibility is necessary for selected-text reading, not for every
    /// Voqora workflow. A completed wizard must therefore stay complete when
    /// someone deliberately continues without that macOS permission; the
    /// dashboard's persistent recovery banner owns the later grant/revoke
    /// path. Reopening a full wizard on every launch would turn a reversible
    /// choice into a product dead end.
    var needsOnboarding: Bool { !hasOnboarded }

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
