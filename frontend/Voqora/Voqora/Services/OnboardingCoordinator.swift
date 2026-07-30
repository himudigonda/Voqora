import Combine
import Foundation
import SwiftUI
import ApplicationServices

/// Single source of truth for first-launch onboarding state.
///
/// Before v1.1 the `hasOnboarded` flag was checked ad hoc in `VoqoraApp.init`
/// and surrounding views. This coordinator centralizes the read/write/reset
/// surface and is the only thing views should consult.
@MainActor
final class OnboardingCoordinator: ObservableObject {
    /// Bump when onboarding flow changes shape; existing users see it again once.
    /// v3: re-runs the permission-led first-use flow for the public Voqora
    /// release after the legacy identity change.
    private static let currentVersion = 3

    @AppStorage("hasOnboarded") private var hasOnboarded: Bool = false
    @AppStorage("onboardingVersion") private var storedVersion: Int = 0

    @Published private(set) var version: Int = 0
    private let accessibilityTrusted: () -> Bool

    init(accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.accessibilityTrusted = accessibilityTrusted
        if storedVersion < Self.currentVersion {
            hasOnboarded = false
            storedVersion = Self.currentVersion
        }
    }

    /// A completed wizard is not sufficient if macOS later revokes or never
    /// granted Accessibility. The selected-text shortcut cannot work without
    /// it, so surface the guided flow again instead of leaving a dead dashboard.
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
