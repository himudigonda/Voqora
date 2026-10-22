import Foundation
@testable import Voqora
import XCTest

final class DictationPreferencesTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "DictationPreferencesTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_defaultsArePrivatePasteWithAutoStopOff() {
        let preferences = DictationPreferences(defaults: defaults)

        XCTAssertNil(preferences.localeIdentifier)
        XCTAssertEqual(preferences.insertionMode, .paste)
        XCTAssertNil(preferences.silenceTimeout)
        XCTAssertFalse(preferences.allowsServerRecognition)
        XCTAssertFalse(preferences.tidiesWithAI)
    }

    func test_storedValuesAreRead() {
        defaults.set("fr_FR", forKey: DictationPreferences.localeKey)
        defaults.set(DictationInsertionMode.copy.rawValue, forKey: DictationPreferences.insertionModeKey)
        defaults.set(3.0, forKey: DictationPreferences.silenceTimeoutKey)
        defaults.set(true, forKey: DictationPreferences.allowsServerRecognitionKey)
        defaults.set(true, forKey: DictationPreferences.tidiesWithAIKey)

        let preferences = DictationPreferences(defaults: defaults)

        XCTAssertEqual(preferences.localeIdentifier, "fr_FR")
        XCTAssertEqual(preferences.insertionMode, .copy)
        XCTAssertEqual(preferences.silenceTimeout, 3)
        XCTAssertTrue(preferences.allowsServerRecognition)
        XCTAssertTrue(preferences.tidiesWithAI)
    }

    func test_invalidStoredValuesFallBackSafely() {
        defaults.set("   ", forKey: DictationPreferences.localeKey)
        defaults.set("type-it-twice", forKey: DictationPreferences.insertionModeKey)

        let preferences = DictationPreferences(defaults: defaults)

        XCTAssertNil(preferences.localeIdentifier)
        XCTAssertEqual(preferences.insertionMode, .paste)
    }

    func test_zeroOrNegativeSilenceTimeoutTurnsAutoStopOff() {
        XCTAssertNil(DictationPreferences.validatedSilenceTimeout(0))
        XCTAssertNil(DictationPreferences.validatedSilenceTimeout(-4))
        XCTAssertNil(DictationPreferences.validatedSilenceTimeout(.infinity))
    }

    func test_silenceTimeoutIsClampedIntoItsRange() {
        XCTAssertEqual(DictationPreferences.validatedSilenceTimeout(0.1), 0.5)
        XCTAssertEqual(DictationPreferences.validatedSilenceTimeout(90), 10)
        XCTAssertNil(DictationPreferences.validatedSilenceTimeout(nil))
    }

    func test_silenceOptionSnapsToTheNearestChoice() {
        XCTAssertEqual(DictationPreferences.silenceOption(closestTo: 2.2), 2)
        XCTAssertEqual(DictationPreferences.silenceOption(closestTo: 9), 5)
        XCTAssertEqual(DictationPreferences.silenceOption(closestTo: 0), 0)
        XCTAssertEqual(DictationPreferences.silenceOption(closestTo: .nan), DictationPreferences.defaultSilenceTimeout)
    }

    func test_silenceLabelNamesTheOffChoiceAndSingularSecond() {
        XCTAssertEqual(DictationPreferences.silenceLabel(for: 0), "Off")
        XCTAssertEqual(DictationPreferences.silenceLabel(for: 1), "After 1 second")
        XCTAssertTrue(DictationPreferences.silenceLabel(for: 3).hasSuffix("seconds"))
    }

    func test_localeOptionsAreDeduplicatedAndSortedByDisplayName() {
        let options = DictationLocaleCatalog.options(
            identifiers: ["fr_FR", "en_US", "de_DE", "en_US"],
            displayLocale: Locale(identifier: "en_US")
        )

        XCTAssertEqual(options.map(\.id), ["en_US", "fr_FR", "de_DE"])
        XCTAssertEqual(options.first?.name, "English (United States)")
    }

    func test_unknownStoredLocaleFallsBackToSystemDefault() {
        let options = [DictationLocaleOption(id: "en_US", name: "English (United States)")]

        XCTAssertEqual(DictationLocaleCatalog.validatedSelection("en_US", among: options), "en_US")
        XCTAssertEqual(DictationLocaleCatalog.validatedSelection("xx_YY", among: options), "")
    }

    func test_localeSupportNotesNeverPromiseServerUseUnlessAllowed() {
        let blocked = DictationLocaleSupport.serverOnly.note(allowsServerRecognition: false)
        let allowed = DictationLocaleSupport.serverOnly.note(allowsServerRecognition: true)

        XCTAssertTrue(blocked.contains("allow server recognition"))
        XCTAssertTrue(allowed.contains("Apple's servers"))
        XCTAssertTrue(DictationLocaleSupport.onDevice.note(allowsServerRecognition: true).contains("never leaves"))
    }

    func test_engineLiveInsertionAndSoundsDefaultToAppleOffAndOn() {
        let preferences = DictationPreferences(defaults: defaults)

        XCTAssertEqual(preferences.engine, .apple)
        XCTAssertFalse(preferences.livesInsertion)
        XCTAssertTrue(preferences.playsSounds)
    }

    func test_engineLiveInsertionAndSoundsAreRead() {
        defaults.set("parakeet", forKey: "dictationEngine")
        defaults.set(true, forKey: "dictationLiveInsertion")
        defaults.set(false, forKey: "voqoraPlaysSounds")

        let preferences = DictationPreferences(defaults: defaults)

        XCTAssertEqual(preferences.engine, .parakeet)
        XCTAssertTrue(preferences.livesInsertion)
        XCTAssertFalse(preferences.playsSounds)
    }

    func test_unknownEngineFallsBackToApple() {
        defaults.set("whisper", forKey: DictationPreferences.engineKey)

        XCTAssertEqual(DictationPreferences(defaults: defaults).engine, .apple)
    }

    func test_parakeetIsEffectiveOnlyWhenInstalled() {
        XCTAssertEqual(DictationEngineChoice.effective(preferred: .parakeet, installed: { _ in true }), .parakeet)
        XCTAssertEqual(DictationEngineChoice.effective(preferred: .parakeet, installed: { _ in false }), .apple)
        XCTAssertEqual(DictationEngineChoice.effective(preferred: .apple, installed: { _ in true }), .apple)
    }
}
