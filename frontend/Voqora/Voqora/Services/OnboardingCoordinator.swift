import Combine
import Foundation

@MainActor
final class OnboardingCoordinator: ObservableObject {
    nonisolated static let hasOnboardedKey = "hasOnboarded"
    nonisolated static let versionKey = "onboardingVersion"
    nonisolated static let stepKey = "onboardingStepKey"
    nonisolated static let seenKey = "onboardingSeenSteps"
    nonisolated static let legacyStepKey = "onboardingStep"
    nonisolated static let currentVersion = 7
    nonisolated static let keysSeenInVersion6: Set<String> = [
        "welcome", "permissions", "engine", "voice", "shortcuts", "audiobooks", "ai", "appearance",
    ]
    nonisolated static let keysSeenInVersion5: Set<String> = [
        "welcome", "permissions", "voice", "shortcuts", "appearance",
    ]

    @Published private(set) var version: Int = 0
    @Published private(set) var seenStepKeys: Set<String> = []
    private let defaults: UserDefaults

    private var hasOnboarded: Bool {
        get { defaults.bool(forKey: Self.hasOnboardedKey) }
        set { defaults.set(newValue, forKey: Self.hasOnboardedKey) }
    }

    private var storedVersion: Int {
        get { defaults.integer(forKey: Self.versionKey) }
        set { defaults.set(newValue, forKey: Self.versionKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        seenStepKeys = Set(defaults.stringArray(forKey: Self.seenKey) ?? [])
        if storedVersion < Self.currentVersion {
            upgrade(from: storedVersion)
        }
    }

    var needsOnboarding: Bool {
        !hasOnboarded
    }

    var resumeStepKey: String? {
        defaults.string(forKey: Self.stepKey)
    }

    func recordStep(key: String) {
        defaults.set(key, forKey: Self.stepKey)
    }

    func markSeen(key: String) {
        guard !seenStepKeys.contains(key) else { return }
        seenStepKeys.insert(key)
        persistSeen()
    }

    func markCompleted() {
        hasOnboarded = true
        storedVersion = Self.currentVersion
        defaults.removeObject(forKey: Self.stepKey)
        version &+= 1
    }

    func reset() {
        hasOnboarded = false
        clearProgress()
        version &+= 1
    }

    private func upgrade(from previousVersion: Int) {
        let carriedOver: Set<String> = switch previousVersion {
        case 6 where hasOnboarded: Self.keysSeenInVersion6
        case 5 where hasOnboarded: Self.keysSeenInVersion5
        default: []
        }
        clearProgress()
        if !carriedOver.isEmpty {
            seenStepKeys = carriedOver
            persistSeen()
        }
        hasOnboarded = false
        storedVersion = Self.currentVersion
    }

    private func clearProgress() {
        seenStepKeys = []
        defaults.removeObject(forKey: Self.seenKey)
        defaults.removeObject(forKey: Self.stepKey)
        defaults.removeObject(forKey: Self.legacyStepKey)
    }

    private func persistSeen() {
        defaults.set(seenStepKeys.sorted(), forKey: Self.seenKey)
    }
}
