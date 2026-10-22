import AppKit
@testable import Voqora
import XCTest

@MainActor
final class VoqoraSoundTests: XCTestCase {
    func test_everySoundMapsToItsKebabCaseFile() {
        XCTAssertEqual(
            VoqoraSound.allCases.map(\.fileName),
            ["dictation-start", "dictation-stop", "dictation-inserted", "dictation-error", "speech-start", "audiobook-ready"]
        )
    }

    func test_everySoundFileShipsInTheAppBundle() {
        for sound in VoqoraSound.allCases {
            XCTAssertNotNil(SoundPlayer.bundleLoader(sound, bundle: .main), "\(sound.fileName) is missing from the app bundle")
        }
    }

    func test_playbackUsesTheQuietVolume() throws {
        let loaded = try XCTUnwrap(NSSound(named: "Glass"))
        _ = SoundPlayer(loader: { _ in loaded }, isEnabled: { false })

        XCTAssertEqual(loaded.volume, SoundPlayer.volume, accuracy: 0.001)
        XCTAssertEqual(SoundPlayer.volume, 0.35, accuracy: 0.001)
    }

    func test_disabledPlayerStaysSilent() throws {
        let loaded = try XCTUnwrap(NSSound(named: "Glass"))
        let player = SoundPlayer(loader: { _ in loaded }, isEnabled: { false })

        player.play(.dictationStart)

        XCTAssertFalse(loaded.isPlaying)
    }

    func test_missingFilesAreSkippedQuietly() {
        let player = SoundPlayer(loader: { _ in nil }, isEnabled: { true })

        player.play(.dictationError)
    }

    func test_soundsAreOnUnlessTurnedOff() throws {
        let suite = "VoqoraSoundTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(DictationPreferences.playsSounds(in: defaults))
        defaults.set(false, forKey: DictationPreferences.playsSoundsKey)
        XCTAssertFalse(DictationPreferences.playsSounds(in: defaults))
    }
}
