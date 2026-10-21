import Foundation
@testable import Voqora
import XCTest

@MainActor
final class SpeechDeliveryTests: XCTestCase {
    private func encoded(_ delivery: SpeechDelivery) throws -> [String: String] {
        let data = try JSONEncoder().encode(delivery)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    private func payload(voice: String, delivery: SpeechDelivery?) -> [String: Any] {
        BackendService.speakPayload(
            text: "Hello",
            voice: voice,
            speed: 1,
            volume: 1,
            pauseScale: 1,
            bookID: nil,
            delivery: delivery
        )
    }

    func test_encodingOmitsEveryUnsetKey() throws {
        XCTAssertEqual(try encoded(SpeechDelivery(emotion: .happy)), ["emotion": "happy"])
        XCTAssertEqual(
            try encoded(SpeechDelivery(emotion: .sad, style: "Whisper", pace: .slow, pitch: .high, dialect: .cantonese)),
            ["emotion": "sad", "style": "Whisper", "pace": "slow", "pitch": "high", "dialect": "cantonese"]
        )
        XCTAssertEqual(try encoded(SpeechDelivery()), [:])
    }

    func test_normalPaceAndPitchAreTheDefaultsAndAreNotSent() throws {
        let delivery = SpeechDelivery(pace: .normal, pitch: .normal)

        XCTAssertTrue(delivery.isEmpty)
        XCTAssertEqual(try encoded(delivery), [:])
    }

    func test_styleIsTrimmedAndCappedAtThreeHundredCharacters() {
        XCTAssertNil(SpeechDelivery(style: "   \n").style)
        XCTAssertEqual(SpeechDelivery(style: "  Calm narrator ").style, "Calm narrator")
        XCTAssertEqual(SpeechDelivery(style: String(repeating: "x", count: 500)).style?.count, 300)
    }

    func test_styleIsNormalizedToPrecomposedForm() {
        let decomposed = "Cafe\u{301} voice"

        XCTAssertEqual(SpeechDelivery(style: decomposed).style, "Caf\u{E9} voice")
    }

    func test_styleDropsControlAndFormatScalarsIncludingZeroWidthJoiners() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"

        XCTAssertEqual(SpeechDelivery(style: "Warm \(family) tone").style, "Warm \u{1F468}\u{1F469}\u{1F467} tone")
        XCTAssertEqual(SpeechDelivery(style: "a\u{0}b\tc\u{200B}d\u{202E}e").style, "abcde")
        XCTAssertNil(SpeechDelivery(style: "\u{200D}\u{200B}").style)
    }

    func test_styleIsCappedByUnicodeScalarsNotCharacters() {
        let overlong = String(repeating: "a", count: 300) + "b"
        XCTAssertEqual(overlong.unicodeScalars.count, 301)

        let style = SpeechDelivery(style: overlong).style

        XCTAssertEqual(style?.unicodeScalars.count, 300)
        XCTAssertEqual(style, String(repeating: "a", count: 300))
        let emoji = String(repeating: "\u{1F600}", count: 301)
        XCTAssertEqual(SpeechDelivery(style: emoji).style?.unicodeScalars.count, 300)
    }

    func test_styleCapDoesNotLeaveTrailingWhitespace() {
        let style = SpeechDelivery(style: String(repeating: "a", count: 299) + "  tail").style

        XCTAssertEqual(style, String(repeating: "a", count: 299))
    }

    func test_cappedStyleKeepsEdgeSpacesWhileTypingButEnforcesTheCap() {
        XCTAssertEqual(SpeechDelivery.cappedStyle("Calm "), "Calm ")
        XCTAssertEqual(SpeechDelivery.cappedStyle(String(repeating: "x", count: 301)).unicodeScalars.count, 300)
        XCTAssertEqual(SpeechDelivery.cappedStyle("a\u{200D}b"), "ab")
    }

    func test_deliverableOnlyForMingVoicesWithSomethingSet() {
        let delivery = SpeechDelivery(emotion: .happy)

        XCTAssertEqual(SpeechDelivery.deliverable(delivery, forVoice: "ming:US_James"), delivery)
        XCTAssertNil(SpeechDelivery.deliverable(delivery, forVoice: "af_bella"))
        XCTAssertNil(SpeechDelivery.deliverable(delivery, forVoice: nil))
        XCTAssertNil(SpeechDelivery.deliverable(SpeechDelivery(), forVoice: "ming:US_James"))
        XCTAssertNil(SpeechDelivery.deliverable(nil, forVoice: "ming:US_James"))
    }

    func test_formValueIsTheJSONObjectTheBackendParses() throws {
        let value = try XCTUnwrap(SpeechDelivery(emotion: .sad, pace: .slow).formValue)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: String])

        XCTAssertEqual(parsed, ["emotion": "sad", "pace": "slow"])
    }

    func test_storedRawValuesRoundTripAndUnknownOnesAreIgnored() {
        let delivery = SpeechDelivery(emotionRaw: "angry", style: "News anchor", paceRaw: "fast", pitchRaw: "", dialectRaw: "klingon")

        XCTAssertEqual(delivery, SpeechDelivery(emotion: .angry, style: "News anchor", pace: .fast))
    }

    func test_speakPayloadCarriesDeliveryForMingVoices() throws {
        let body = payload(voice: "ming:US_James", delivery: SpeechDelivery(emotion: .happy, pace: .fast))

        let delivery = try XCTUnwrap(body["delivery"] as? [String: String])
        XCTAssertEqual(delivery, ["emotion": "happy", "pace": "fast"])
        XCTAssertEqual(body["voice"] as? String, "ming:US_James")
    }

    func test_speakPayloadNeverCarriesDeliveryForOtherEngines() {
        let delivery = SpeechDelivery(emotion: .happy)

        XCTAssertNil(payload(voice: "af_bella", delivery: delivery)["delivery"])
        XCTAssertNil(payload(voice: "supertonic:M1", delivery: delivery)["delivery"])
        XCTAssertNil(payload(voice: "blend:3f2b8c1e-4d5a-4b6c-9e7f-0a1b2c3d4e5f", delivery: delivery)["delivery"])
    }

    func test_speakPayloadOmitsDeliveryWhenNothingIsSet() {
        XCTAssertNil(payload(voice: "ming:US_James", delivery: nil)["delivery"])
        XCTAssertNil(payload(voice: "ming:US_James", delivery: SpeechDelivery())["delivery"])
    }

    func test_tailoringOnlyAppliesToMingVoices() {
        let delivery = SpeechDelivery(emotion: .happy)

        XCTAssertNil(delivery.tailored(forVoice: "af_bella", known: nil))
        XCTAssertEqual(delivery.tailored(forVoice: "ming:US_James", known: nil), delivery)
        XCTAssertNil(SpeechDelivery().tailored(forVoice: "ming:US_James", known: nil))
    }

    func test_tailoringKeepsEveryEmotionForEveryMingVoice() {
        let narrow = SpeechEngineVoice(id: "ming:US_James", name: "James", gender: "male", lang: "en", emotions: ["neutral", "happy"])
        let open = SpeechEngineVoice(id: "ming:US_Ann", name: "Ann", gender: "female", lang: "en")

        for emotion in MingEmotion.allCases {
            XCTAssertEqual(SpeechDelivery(emotion: emotion).tailored(forVoice: narrow.id, known: narrow)?.emotion, emotion)
            XCTAssertEqual(SpeechDelivery(emotion: emotion).tailored(forVoice: open.id, known: open)?.emotion, emotion)
        }
    }

    func test_tailoringKeepsADialectOnlyForChineseVoices() {
        let chinese = SpeechEngineVoice(id: "ming:CN_A", name: "A", gender: "female", lang: "zh")
        let english = SpeechEngineVoice(id: "ming:US_B", name: "B", gender: "male", lang: "en")
        let delivery = SpeechDelivery(emotion: .happy, dialect: .sichuanese)

        XCTAssertEqual(delivery.tailored(forVoice: chinese.id, known: chinese)?.dialect, .sichuanese)
        XCTAssertNil(delivery.tailored(forVoice: english.id, known: english)?.dialect)
        XCTAssertNil(SpeechDelivery(dialect: .cantonese).tailored(forVoice: english.id, known: english))
    }
}
