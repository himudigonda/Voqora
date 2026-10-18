import Foundation
@testable import Voqora
import XCTest

@MainActor
final class VoiceBlendModelTests: XCTestCase {
    nonisolated static let blendID = "blend:3f2b8c1e-4d5a-4b6c-9e7f-0a1b2c3d4e5f"

    nonisolated static let blendJSON = """
    {"id":"\(blendID)","name":"Warm Narrator","lang":"en-us","version":2,
     "components":[{"voice":"af_bella","weight":0.6,"normalized_weight":0.6},
                   {"voice":"am_adam","weight":0.4,"normalized_weight":0.4}],
     "created_at":"2026-10-01T10:00:00Z","updated_at":"2026-10-02T10:00:00Z"}
    """

    func test_isBlendID_acceptsOnlyLowercaseUUIDsWithThePrefix() {
        XCTAssertTrue(VoiceBlendRules.isBlendID(Self.blendID))
        XCTAssertFalse(VoiceBlendRules.isBlendID("blend:3F2B8C1E-4D5A-4B6C-9E7F-0A1B2C3D4E5F"))
        XCTAssertFalse(VoiceBlendRules.isBlendID("3f2b8c1e-4d5a-4b6c-9e7f-0a1b2c3d4e5f"))
        XCTAssertFalse(VoiceBlendRules.isBlendID("blend:not-a-uuid"))
        XCTAssertFalse(VoiceBlendRules.isBlendID("af_bella"))
        XCTAssertFalse(VoiceBlendRules.isBlendID(""))
    }

    func test_telemetryVoice_neverSendsBlendIdentifiers() {
        XCTAssertEqual(VoiceBlendRules.telemetryVoice(Self.blendID), "blend")
        XCTAssertEqual(VoiceBlendRules.telemetryVoice("af_bella"), "af_bella")
    }

    func test_blendDecodesSnakeCaseFields() throws {
        let blend = try JSONDecoder().decode(VoiceBlend.self, from: Data(Self.blendJSON.utf8))

        XCTAssertEqual(blend.id, Self.blendID)
        XCTAssertEqual(blend.name, "Warm Narrator")
        XCTAssertEqual(blend.version, 2)
        XCTAssertEqual(blend.components.map(\.voice), ["af_bella", "am_adam"])
        XCTAssertEqual(blend.components.first?.normalizedWeight, 0.6)
        XCTAssertEqual(blend.createdAt, "2026-10-01T10:00:00Z")
        XCTAssertEqual(blend.fallbackVoice, "af_bella")
    }

    func test_blendListDecodesTheLimit() throws {
        let json = #"{"blends":[\#(Self.blendJSON)],"max_blends":50}"#
        let list = try JSONDecoder().decode(VoiceBlendList.self, from: Data(json.utf8))

        XCTAssertEqual(list.blends.count, 1)
        XCTAssertEqual(list.maxBlends, 50)
    }

    func test_newDraftStartsValidOnceNamed() {
        var draft = VoiceBlendDraft()
        XCTAssertEqual(draft.validationMessage, "Give your voice a name.")

        draft.name = "  Duo  "

        XCTAssertNil(draft.validationMessage)
        XCTAssertEqual(draft.request.name, "Duo")
        XCTAssertEqual(draft.components.count, 2)
    }

    func test_draftRejectsLongNamesDuplicatesAndBadWeights() {
        var draft = VoiceBlendDraft(name: String(repeating: "a", count: 41))
        XCTAssertEqual(draft.validationMessage, "Keep the name to 40 characters or fewer.")

        draft.name = "Duo"
        draft.components[1].voice = draft.components[0].voice
        XCTAssertEqual(draft.validationMessage, "Each voice can appear only once in a blend.")

        draft.components[1].voice = Self.blendID
        XCTAssertEqual(draft.validationMessage, "Blends can only mix built-in voices.")

        draft.components[1].voice = "am_adam"
        draft.components[1].weight = 0.01
        XCTAssertEqual(draft.validationMessage, "Each weight must be between 5% and 100%.")
    }

    func test_draftAddsAndRemovesWithinTheTwoToFourLimit() {
        var draft = VoiceBlendDraft(name: "Choir")
        let firstID = draft.components[0].id

        draft.removeComponent(firstID)
        XCTAssertEqual(draft.components.count, 2)

        draft.addComponent()
        draft.addComponent()
        XCTAssertEqual(draft.components.count, 4)
        XCTAssertFalse(draft.canAddComponent)

        draft.addComponent()
        XCTAssertEqual(draft.components.count, 4)
        XCTAssertEqual(Set(draft.components.map(\.voice)).count, 4)

        draft.removeComponent(firstID)
        XCTAssertEqual(draft.components.count, 3)
        XCTAssertTrue(draft.isValid)
    }

    func test_shareReflectsRelativeWeights() {
        let draft = VoiceBlendDraft(name: "Duo", components: [
            .init(voice: "af_bella", weight: 0.75),
            .init(voice: "am_adam", weight: 0.25),
        ])

        XCTAssertEqual(draft.share(of: draft.components[0]), 0.75, accuracy: 0.0001)
        XCTAssertEqual(draft.share(of: draft.components[1]), 0.25, accuracy: 0.0001)
    }

    func test_requestEncodesOnlyVoiceAndWeight() throws {
        let blend = try JSONDecoder().decode(VoiceBlend.self, from: Data(Self.blendJSON.utf8))
        let data = try JSONEncoder().encode(VoiceBlendDraft(blend: blend).request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let components = try XCTUnwrap(object["components"] as? [[String: Any]])

        XCTAssertEqual(object["name"] as? String, "Warm Narrator")
        XCTAssertEqual(components.count, 2)
        XCTAssertEqual(Set(components[0].keys), ["voice", "weight"])
        XCTAssertEqual(components[0]["weight"] as? Double, 0.6)
    }
}
