import Combine
import Foundation

@MainActor
final class OnboardingCoordinator: ObservableObject {
    private static let currentVersion = 5

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

    private var storedStep: Int {
        get { defaults.integer(forKey: "onboardingStep") }
        set { defaults.set(newValue, forKey: "onboardingStep") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if storedVersion < Self.currentVersion {
            hasOnboarded = false
            storedVersion = Self.currentVersion
        }
    }

    var needsOnboarding: Bool {
        !hasOnboarded
    }

    var resumeStep: Int {
        storedStep
    }

    func recordStep(_ step: Int) {
        storedStep = step
    }

    func markCompleted() {
        hasOnboarded = true
        storedVersion = Self.currentVersion
        storedStep = 0
        version &+= 1
    }

    func reset() {
        hasOnboarded = false
        storedStep = 0
        version &+= 1
    }
}
