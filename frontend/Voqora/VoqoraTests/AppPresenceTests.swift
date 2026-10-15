import AppKit
@testable import Voqora
import XCTest

final class AppPresenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppPresenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsKeepDockAndMenuBarIcon() {
        XCTAssertFalse(AppPresence.hidesFromDock(defaults))
        XCTAssertNil(defaults.object(forKey: AppPresence.showMenuBarIconKey))
    }

    func testHidingFromDockForcesMenuBarIconOn() {
        AppPresence.setShowMenuBarIcon(false, defaults: defaults)

        AppPresence.setHideFromDock(true, defaults: defaults)

        XCTAssertTrue(AppPresence.hidesFromDock(defaults))
        XCTAssertTrue(defaults.bool(forKey: AppPresence.showMenuBarIconKey))
    }

    func testRemovingMenuBarIconBringsBackTheDock() {
        AppPresence.setHideFromDock(true, defaults: defaults)

        AppPresence.setShowMenuBarIcon(false, defaults: defaults)

        XCTAssertFalse(AppPresence.hidesFromDock(defaults))
        XCTAssertFalse(defaults.bool(forKey: AppPresence.showMenuBarIconKey))
    }

    func testOnboardingAlwaysUsesTheDock() {
        XCTAssertEqual(AppPresence.activationPolicy(hideFromDock: true, onboarding: true), .regular)
        XCTAssertEqual(AppPresence.activationPolicy(hideFromDock: true, onboarding: false), .accessory)
        XCTAssertEqual(AppPresence.activationPolicy(hideFromDock: false, onboarding: false), .regular)
    }

    func testConfirmingOptOutTurnsAnalyticsOffAndDiscardsPendingEvents() {
        defaults.set(true, forKey: MetricsService.analyticsEnabledKey)
        var discarded = false

        AnalyticsOptOut.confirm(defaults: defaults) { discarded = true }

        XCTAssertFalse(MetricsService.userAllowsAnalytics(defaults))
        XCTAssertTrue(discarded)
    }

    func testOptOutCopyMatchesThePrivacyPolicy() {
        XCTAssertFalse(AnalyticsOptOut.note.localizedCaseInsensitiveContains("personal information"))
        for never in ["text", "documents", "audio", "API keys"] {
            XCTAssertTrue(AnalyticsOptOut.note.contains(never), never)
        }
    }
}
