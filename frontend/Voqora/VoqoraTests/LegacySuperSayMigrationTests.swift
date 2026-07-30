import XCTest
@testable import Voqora

@MainActor
final class LegacySuperSayMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var legacyDefaults: UserDefaults!
    private var defaultsName = ""
    private var legacyDefaultsName = ""

    override func setUp() {
        super.setUp()
        let id = UUID().uuidString
        defaultsName = "LegacyMigrationTests.\(id)"
        legacyDefaultsName = "LegacyMigrationLegacyTests.\(id)"
        defaults = UserDefaults(suiteName: defaultsName)!
        legacyDefaults = UserDefaults(suiteName: legacyDefaultsName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsName)
        legacyDefaults.removePersistentDomain(forName: legacyDefaultsName)
        defaults = nil
        legacyDefaults = nil
        super.tearDown()
    }

    func testDetectsLegacyInstallOnceAndRecordsRemovalOnce() {
        var events: [LegacySuperSayMigration.Event] = []
        let appURL = URL(fileURLWithPath: "/Applications/SuperSay.app")
        var installed = true
        let migration = LegacySuperSayMigration(
            defaults: defaults,
            legacyDefaults: legacyDefaults,
            locateLegacyApp: { installed ? appURL : nil },
            recordEvent: { events.append($0) }
        )

        migration.evaluate()
        migration.evaluate()
        XCTAssertTrue(migration.isLegacyInstalled)
        XCTAssertTrue(migration.shouldPresentNotice)
        XCTAssertEqual(events, [.detected])

        installed = false
        migration.evaluate()
        migration.evaluate()
        XCTAssertFalse(migration.isLegacyInstalled)
        XCTAssertEqual(events, [.detected, .removed])
    }

    func testImportsOnlyCompatibleExplicitPreferencesAndRecordsOnce() {
        legacyDefaults.set("af_bella", forKey: "selectedVoice")
        legacyDefaults.set(1.25, forKey: "speechSpeed")
        legacyDefaults.set(1.0, forKey: "speechVolume")
        legacyDefaults.set(true, forKey: "enableDucking")
        legacyDefaults.set(false, forKey: "cleanURLs")
        legacyDefaults.set("dark", forKey: "appTheme")
        legacyDefaults.set("Poppins", forKey: "selectedFontName")
        legacyDefaults.set("must-not-copy@example.com", forKey: "lastSignedEmail")
        legacyDefaults.set(false, forKey: "telemetryEnabled")
        legacyDefaults.set("bad_voice", forKey: "defaultBookVoice")

        var events: [LegacySuperSayMigration.Event] = []
        let migration = LegacySuperSayMigration(
            defaults: defaults,
            legacyDefaults: legacyDefaults,
            locateLegacyApp: { nil },
            recordEvent: { events.append($0) }
        )

        XCTAssertEqual(migration.importCompatiblePreferences(), 7)
        XCTAssertEqual(defaults.string(forKey: "selectedVoice"), "af_bella")
        XCTAssertEqual(defaults.double(forKey: "speechSpeed"), 1.25)
        XCTAssertEqual(defaults.double(forKey: "speechVolume"), 1.0)
        XCTAssertTrue(defaults.bool(forKey: "enableDucking"))
        XCTAssertFalse(defaults.bool(forKey: "cleanURLs"))
        XCTAssertEqual(defaults.string(forKey: "appTheme"), "dark")
        XCTAssertEqual(defaults.string(forKey: "selectedFontName"), "Poppins")
        XCTAssertNil(defaults.string(forKey: "lastSignedEmail"))
        XCTAssertNil(defaults.object(forKey: "telemetryEnabled"))
        XCTAssertEqual(events, [.completed])

        XCTAssertEqual(migration.importCompatiblePreferences(), 7)
        XCTAssertEqual(events, [.completed])
    }
}
