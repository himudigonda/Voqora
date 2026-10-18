@testable import Voqora
import XCTest

@MainActor
final class ReadingPreferencesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ReadingPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_freshPreferencesUseComfortableDefaults() {
        let preferences = ReadingPreferences(defaults: defaults)

        XCTAssertEqual(preferences.typography, .standard)
        XCTAssertEqual(preferences.theme, .paper)
        XCTAssertEqual(preferences.tint, .clear)
        XCTAssertTrue(preferences.showsRuler)
        XCTAssertTrue(preferences.emphasizesWords)
    }

    func test_changesPersistAcrossInstances() {
        let preferences = ReadingPreferences(defaults: defaults)
        preferences.typography = ReadingTypography(fontSize: 32, family: .serif, letterSpacing: 0.1, wordSpacing: 0.4, lineHeight: 2.0)
        preferences.theme = .sepia
        preferences.tint = .mint
        preferences.showsRuler = false
        preferences.emphasizesWords = false

        let reloaded = ReadingPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.typography, preferences.typography)
        XCTAssertEqual(reloaded.theme, .sepia)
        XCTAssertEqual(reloaded.tint, .mint)
        XCTAssertFalse(reloaded.showsRuler)
        XCTAssertFalse(reloaded.emphasizesWords)
        XCTAssertEqual(defaults.double(forKey: ReadingPreferences.Keys.fontSize), 32)
        XCTAssertEqual(defaults.string(forKey: ReadingPreferences.Keys.fontFamily), "serif")
    }

    func test_corruptStoredValuesFallBackSafely() {
        defaults.set(900.0, forKey: ReadingPreferences.Keys.fontSize)
        defaults.set(0.1, forKey: ReadingPreferences.Keys.lineHeight)
        defaults.set("comic", forKey: ReadingPreferences.Keys.fontFamily)
        defaults.set("neon", forKey: ReadingPreferences.Keys.theme)
        defaults.set("glitter", forKey: ReadingPreferences.Keys.tint)
        defaults.set("yes", forKey: ReadingPreferences.Keys.showsRuler)

        let preferences = ReadingPreferences(defaults: defaults)

        XCTAssertEqual(preferences.typography.fontSize, 48)
        XCTAssertEqual(preferences.typography.lineHeight, 1.0)
        XCTAssertEqual(preferences.typography.family, .standard)
        XCTAssertEqual(preferences.theme, .paper)
        XCTAssertEqual(preferences.tint, .clear)
        XCTAssertTrue(preferences.showsRuler)
    }

    func test_resetRestoresDefaultsAndPersistsThem() {
        let preferences = ReadingPreferences(defaults: defaults)
        preferences.typography.fontSize = 40
        preferences.theme = .dark
        preferences.tint = .rose
        preferences.showsRuler = false

        preferences.resetToDefaults()

        let reloaded = ReadingPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.typography, .standard)
        XCTAssertEqual(reloaded.theme, .paper)
        XCTAssertEqual(reloaded.tint, .clear)
        XCTAssertTrue(reloaded.showsRuler)
    }

    func test_sourcePrefersTheLoadedAudiobookTranscript() {
        XCTAssertEqual(ReadingSource.resolve(audiobookTranscript: .loaded, hasSpokenText: true), .audiobook)
        XCTAssertEqual(ReadingSource.resolve(audiobookTranscript: .loading, hasSpokenText: true), .loading)
        XCTAssertEqual(ReadingSource.resolve(audiobookTranscript: .idle, hasSpokenText: false), .loading)
        XCTAssertEqual(ReadingSource.resolve(audiobookTranscript: .unavailable, hasSpokenText: true), .unavailable)
    }

    func test_sourceUsesSpokenTextWithoutAnAudiobook() {
        XCTAssertEqual(ReadingSource.resolve(audiobookTranscript: nil, hasSpokenText: true), .speech)
        XCTAssertEqual(ReadingSource.resolve(audiobookTranscript: nil, hasSpokenText: false), .empty)
    }
}
