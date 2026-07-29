import ApplicationServices
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
    /// v3 (Jun 2026): added the voice/language/speed personalization step.
    private static let currentVersion = 3

    @AppStorage("hasOnboarded") private var hasOnboarded: Bool = false
    @AppStorage("onboardingVersion") private var storedVersion: Int = 0

    @Published private(set) var version: Int = 0

    init() {
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
    /// In XCTest hosts `AXIsProcessTrusted()` is always false, so we ignore the
    /// permission check there (otherwise every test would force onboarding).
    var needsOnboarding: Bool {
        if !hasOnboarded {
            return true
        }
        if NSClassFromString("XCTestCase") != nil {
            return false
        }
        return !AXIsProcessTrusted()
    }

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
