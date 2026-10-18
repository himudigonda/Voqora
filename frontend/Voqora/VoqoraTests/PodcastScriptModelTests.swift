import Foundation
@testable import Voqora
import XCTest

@MainActor
final class PodcastScriptModelTests: XCTestCase {
    func test_scriptRoundTripsWithBackendKeys() throws {
        var script = StudioFixtures.script()
        script.turns[1].section = "Part Two"
        script.turns[1].pauseAfterSeconds = 1.5

        let data = try JSONEncoder().encode(script)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let turns = try XCTUnwrap(object["turns"] as? [[String: Any]])
        XCTAssertEqual(Set(turns[1].keys), ["speaker_id", "text", "pause_after_seconds", "section"])
        XCTAssertEqual(Set(turns[0].keys), ["speaker_id", "text", "pause_after_seconds"])

        let decoded = try JSONDecoder().decode(PodcastScript.self, from: data)
        XCTAssertEqual(decoded.title, script.title)
        XCTAssertEqual(decoded.speakers, script.speakers)
        XCTAssertEqual(decoded.turns.map(\.text), script.turns.map(\.text))
        XCTAssertEqual(decoded.turns[1].section, "Part Two")
        XCTAssertEqual(decoded.turns[1].pauseAfterSeconds, 1.5)
    }

    func test_normalizedForRenderTrimsAndClearsBlankChapters() {
        var script = StudioFixtures.script()
        script.title = "  Night   Sky \n"
        script.speakers[0].name = " Avery  Lee "
        script.turns[0].text = "\n Hello there.  "
        script.turns[0].section = "   "
        script.turns[1].section = "  The   End "

        let normalized = script.normalizedForRender()

        XCTAssertEqual(normalized.title, "Night Sky")
        XCTAssertEqual(normalized.speakers[0].name, "Avery Lee")
        XCTAssertEqual(normalized.turns[0].text, "Hello there.")
        XCTAssertNil(normalized.turns[0].section)
        XCTAssertEqual(normalized.turns[1].section, "The End")
        XCTAssertEqual(normalized.turns.map(\.id), script.turns.map(\.id))
    }

    func test_estimatedAudioMirrorsBackendFormula() {
        var script = StudioFixtures.script(turns: 1)
        script.turns[0].text = String(repeating: "word ", count: 11)
        script.turns[0].pauseAfterSeconds = 1

        XCTAssertEqual(script.estimatedAudioSeconds, 11 / 2.75 + 1, accuracy: 0.0001)
    }

    func test_nextSpeakerIDSkipsTakenIDs() {
        var script = StudioFixtures.script()
        script.speakers.append(PodcastSpeaker(id: "host_3", name: "Sam", voice: "af_sarah"))
        script.speakers.remove(at: 0)

        XCTAssertEqual(script.nextSpeakerID(), "host_4")
    }

    func test_audiobookDecodesPodcastKindAndSpeakers() throws {
        let json = """
        {"book_id":"abc","title":"Night Sky","created_at":"2026-01-01T00:00:00Z","page_count":2,"status":"done",
        "phase_progress":{"page_done":2,"page_total":2},"sections":[],"page_to_time":{},"total_audio_seconds":10,
        "failed_pages":[],"engine":"kokoro","voice":"af_bella","speed":1.0,"kind":"podcast",
        "speakers":[{"id":"host_1","name":"Avery","voice":"af_bella"},{"id":"host_2","name":"Jordan","voice":"am_adam"}]}
        """

        let book = try JSONDecoder().decode(Audiobook.self, from: Data(json.utf8))

        XCTAssertTrue(book.isPodcast)
        XCTAssertEqual(book.creditLine, "With \(ListFormatter.localizedString(byJoining: ["Avery", "Jordan"]))")
        XCTAssertEqual(book.subtitle(at: 0), book.creditLine)
    }

    func test_audiobookWithoutKindIsABook() throws {
        let json = """
        {"book_id":"abc","title":"Novel","created_at":"2026-01-01T00:00:00Z","page_count":2,"status":"done",
        "phase_progress":{"page_done":2,"page_total":2},"sections":[],"page_to_time":{},"total_audio_seconds":10,
        "failed_pages":[],"engine":"kokoro","voice":"af_bella","speed":1.0}
        """

        let book = try JSONDecoder().decode(Audiobook.self, from: Data(json.utf8))

        XCTAssertFalse(book.isPodcast)
        XCTAssertEqual(book.creditLine, "Narrated by Bella")
    }

    func test_transcriptCarriesSpeakerNamesAndLabelsChanges() throws {
        let json = """
        {"book_id":"abc","sections":[],"page_to_time":{"1":0,"2":2},"total_audio_seconds":4,"pages":{"1":"Hi.","2":"Hello."},
        "lines":{"1":[{"paragraph":0,"text":"Hi.","start":0,"end":1,"speaker_id":"host_1","speaker":"Avery"},
        {"paragraph":1,"text":"Again.","start":1,"end":2,"speaker_id":"host_1","speaker":"Avery"}],
        "2":[{"paragraph":0,"text":"Hello.","start":2,"end":4,"speaker_id":"host_2","speaker":"Jordan"}]}}
        """
        let transcript = try JSONDecoder().decode(AudiobookService.Transcript.self, from: Data(json.utf8))

        let document = TranscriptDocument(transcript: transcript)

        XCTAssertEqual(document.lines.map(\.speaker), ["Avery", "Avery", "Jordan"])
        XCTAssertEqual(document.speakerLabel(at: 0), "Avery")
        XCTAssertNil(document.speakerLabel(at: 1))
        XCTAssertEqual(document.speakerLabel(at: 2), "Jordan")
        XCTAssertNil(document.speakerLabel(at: 9))
    }

    func test_bookTranscriptHasNoSpeakerLabels() throws {
        let json = """
        {"book_id":"abc","sections":[],"page_to_time":{"1":0},"total_audio_seconds":1,"pages":{"1":"Hi."},
        "lines":{"1":[{"paragraph":0,"text":"Hi.","start":0,"end":1}]}}
        """
        let transcript = try JSONDecoder().decode(AudiobookService.Transcript.self, from: Data(json.utf8))

        XCTAssertNil(TranscriptDocument(transcript: transcript).speakerLabel(at: 0))
    }

    func test_scriptResultDecodesBackendResponse() throws {
        let json = """
        {"script":{"title":"T","speakers":[{"id":"host_1","name":"A","voice":"af_bella"}],"turns":[{"speaker_id":"host_1","text":"Hi","pause_after_seconds":0.4,"section":null}]},
        "used_notes":false,"repaired":true,"source_truncated":false,"estimated_audio_seconds":3.2,"llm_provider":"google","llm_model":"gemini"}
        """

        let result = try JSONDecoder().decode(PodcastScriptResult.self, from: Data(json.utf8))

        XCTAssertTrue(result.repaired)
        XCTAssertNil(result.script.turns[0].section)
        XCTAssertEqual(result.llmProvider, "google")
    }
}
