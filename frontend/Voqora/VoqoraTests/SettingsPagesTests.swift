@testable import Voqora
import XCTest

final class SettingsPagesTests: XCTestCase {
    func testEveryTabHasUniqueTitleSymbolAndOneLineSummary() {
        let tabs = SettingsTab.allCases
        XCTAssertEqual(tabs.count, 12)
        XCTAssertEqual(Set(tabs.map(\.title)).count, tabs.count)
        XCTAssertEqual(Set(tabs.map(\.symbol)).count, tabs.count)
        for tab in tabs {
            XCTAssertFalse(tab.summary.contains("\n"), tab.title)
            XCTAssertLessThanOrEqual(tab.summary.count, 90, tab.title)
        }
    }

    func test_permissionsTabRoutes() {
        XCTAssertEqual(SettingsTab.allCases.dropFirst().first, .permissions)
        XCTAssertEqual(SettingsTab.permissions.title, "Permissions")
        XCTAssertEqual(SettingsTab.permissions.symbol, "lock.shield")
        XCTAssertEqual(TabKey.settings(.permissions), SetupChecklist.permissionsTarget)
        XCTAssertEqual(TabKey.settingsTab(for: SetupChecklist.permissionsTarget), .permissions)
        XCTAssertEqual(TabKey.title(for: "settings.permissions"), "Permissions")
        XCTAssertTrue(TabKey.all.contains("settings.permissions"))
    }

    func testPrivacyReplacesAdvanced() {
        XCTAssertNil(SettingsTab(rawValue: "advanced"))
        XCTAssertEqual(SettingsTab.privacy.title, "Privacy & Data")
        XCTAssertEqual(TabKey.canonical("settings.advanced"), TabKey.settings(.privacy))
        XCTAssertFalse(TabKey.all.contains("settings.advanced"))
    }

    func testEveryTabRoundTripsThroughRoutingKeys() {
        for tab in SettingsTab.allCases {
            XCTAssertEqual(TabKey.settingsTab(for: TabKey.settings(tab)), tab)
            XCTAssertEqual(TabKey.title(for: TabKey.settings(tab)), tab.title)
        }
    }

    func testEngineLicenseNotesStayAttached() {
        XCTAssertTrue(SpeechEnginesSection.licenseNote.contains("OpenRAIL-M"))
        XCTAssertTrue(SpeechEnginesSection.mingLicenseNote.contains("MIT"))
    }

    func testEngineRowTextFormatsProgressWithinBounds() {
        XCTAssertEqual(SpeechEngineRowText.percent(-1), "0%")
        XCTAssertEqual(SpeechEngineRowText.percent(0.426), "43%")
        XCTAssertEqual(SpeechEngineRowText.percent(7), "100%")
    }

    func testProviderRemovalNoticeMentionsRemainingProviderWhenActive() {
        let message = ProviderRemovalNotice.message(
            provider: .openai,
            isActive: true,
            cleaningCount: 0,
            remaining: [.anthropic]
        )
        XCTAssertTrue(message.contains("Anthropic"))
        XCTAssertTrue(message.contains("Keychain"))
    }
}
