import Combine
import Foundation
import SwiftUI

/// Single source of truth for first-launch onboarding state.
///
/// Before v1.1 the `hasOnboarded` flag was checked ad hoc in `VoqoraApp.init`
/// and surrounding views. This coordinator centralizes the read/write/reset
/// surface and is the only thing views should consult.
@MainActor
final class OnboardingCoordinator: ObservableObject {
    /// Bump when onboarding flow changes shape; existing users see it again once.
    /// v2 (Jun 2026): replaced 5-step sign-in nudge with 6-step permission wizard.
    private static let currentVersion = 2

    @AppStorage("hasOnboarded") private var hasOnboarded: Bool = false
    @AppStorage("onboardingVersion") private var storedVersion: Int = 0

    @Published private(set) var version: Int = 0

    init() {
        if storedVersion < Self.currentVersion {
            hasOnboarded = false
            storedVersion = Self.currentVersion
        }
    }

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
