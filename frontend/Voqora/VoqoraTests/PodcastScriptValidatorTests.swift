import Foundation
@testable import Voqora
import XCTest

@MainActor
final class PodcastScriptValidatorTests: XCTestCase {
    func test_validScriptHasNoIssues() {
        XCTAssertEqual(PodcastScriptValidator.issues(in: StudioFixtures.script()), [])
    }

    func test_titleMustBePresentAndShort() {
        var script = StudioFixtures.script()
        script.title = "   "
        XCTAssertEqual(PodcastScriptValidator.issues(in: script), [.missingTitle])

        script.title = String(repeating: "t", count: PodcastLimits.titleCharacters + 1)
        XCTAssertEqual(PodcastScriptValidator.issues(in: script), [.titleTooLong])
    }

    func test_speakerCountMirrorsBackendLimits() {
        var script = StudioFixtures.script()
        script.speakers = []
        XCTAssertTrue(PodcastScriptValidator.issues(in: script).contains(.tooFewSpeakers))

        script = StudioFixtures.script()
        script.speakers = (1 ... 5).map { PodcastSpeaker(id: "host_\($0)", name: "Host \($0)", voice: "af_bella") }
        XCTAssertTrue(PodcastScriptValidator.issues(in: script).contains(.tooManySpeakers))
    }

    func test_speakerFieldsAreChecked() {
        var script = StudioFixtures.script()
        script.speakers[0].name = " "
        script.speakers[1].voice = ""
        script.speakers.append(PodcastSpeaker(id: "host_1", name: String(repeating: "n", count: 61), voice: "af_bella"))
        script.speakers.append(PodcastSpeaker(id: "bad id", name: "Sam", voice: "af_bella"))

        let issues = PodcastScriptValidator.issues(in: script)

        XCTAssertTrue(issues.contains(.missingSpeakerName(speaker: 0)))
        XCTAssertTrue(issues.contains(.missingVoice(speaker: 1)))
        XCTAssertTrue(issues.contains(.duplicateSpeakerID(speaker: 2)))
        XCTAssertTrue(issues.contains(.speakerNameTooLong(speaker: 2)))
        XCTAssertTrue(issues.contains(.invalidSpeakerID(speaker: 3)))
        XCTAssertEqual(PodcastScriptIssue.missingSpeakerName(speaker: 0).speakerIndex, 0)
    }

    func test_turnCountMirrorsBackendLimits() {
        var script = StudioFixtures.script()
        script.turns = []
        XCTAssertEqual(PodcastScriptValidator.issues(in: script), [.tooFewTurns])

        script = StudioFixtures.script(turns: PodcastLimits.turns.upperBound + 1)
        XCTAssertEqual(PodcastScriptValidator.issues(in: script), [.tooManyTurns])

        script = StudioFixtures.script(turns: PodcastLimits.turns.upperBound)
        XCTAssertEqual(PodcastScriptValidator.issues(in: script), [])
    }

    func test_turnTextMustBeSpokenAndShort() {
        var script = StudioFixtures.script(turns: 3)
        script.turns[0].text = " \n "
        script.turns[1].text = "-"
        script.turns[2].text = String(repeating: "a", count: PodcastLimits.turnCharacters + 1)

        XCTAssertEqual(PodcastScriptValidator.issues(in: script), [
            .emptyTurn(turn: 0),
            .emptyTurn(turn: 1),
            .turnTooLong(turn: 2, length: PodcastLimits.turnCharacters + 1),
        ])
    }

    func test_turnLengthCountsUnicodeScalarsLikeTheBackend() {
        var script = StudioFixtures.script(turns: 1)
        script.turns[0].text = String(repeating: "\u{1F469}\u{200D}\u{1F680}", count: 700)

        XCTAssertEqual(PodcastScriptValidator.issues(in: script), [.turnTooLong(turn: 0, length: 2100)])
    }

    func test_turnFieldsAreChecked() {
        var script = StudioFixtures.script(turns: 3)
        script.turns[0].speakerID = "ghost"
        script.turns[1].pauseAfterSeconds = 3.5
        script.turns[2].section = String(repeating: "s", count: PodcastLimits.sectionCharacters + 1)

        let issues = PodcastScriptValidator.issues(in: script)

        XCTAssertEqual(issues, [.unknownSpeaker(turn: 0), .invalidPause(turn: 1), .sectionTooLong(turn: 2)])
        XCTAssertEqual(PodcastScriptValidator.issuesByTurn(issues)[1], [.invalidPause(turn: 1)])
        XCTAssertFalse(issues.map(\.message).contains(where: \.isEmpty))
    }

    func test_pauseBoundsAreInclusive() {
        var script = StudioFixtures.script()
        script.turns[0].pauseAfterSeconds = 0
        script.turns[1].pauseAfterSeconds = 3

        XCTAssertEqual(PodcastScriptValidator.issues(in: script), [])
    }

    func test_speakerIDPattern() {
        XCTAssertTrue(PodcastScriptValidator.isSpeakerIDValid("host_1"))
        XCTAssertTrue(PodcastScriptValidator.isSpeakerIDValid("Guest-2"))
        XCTAssertFalse(PodcastScriptValidator.isSpeakerIDValid(""))
        XCTAssertFalse(PodcastScriptValidator.isSpeakerIDValid("has space"))
        XCTAssertFalse(PodcastScriptValidator.isSpeakerIDValid(String(repeating: "a", count: 33)))
    }
}
