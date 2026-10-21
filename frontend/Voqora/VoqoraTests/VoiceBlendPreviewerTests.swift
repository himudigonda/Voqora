import AVFoundation
import Foundation
@testable import Voqora
import XCTest

@MainActor
private final class StubPreviewService: VoiceBlendServing {
    var audio = Data([1, 2, 3])
    var error: Error?
    var holdsResponse = false
    private(set) var previewed: [VoiceBlendPreviewRequest] = []
    private(set) var savedCalls = 0

    func list() async throws -> VoiceBlendList {
        throw BackendAPIError.unreachable
    }

    func create(_: VoiceBlendRequest) async throws -> VoiceBlend {
        savedCalls += 1
        throw BackendAPIError.unreachable
    }

    func update(id _: String, with _: VoiceBlendRequest) async throws -> VoiceBlend {
        savedCalls += 1
        throw BackendAPIError.unreachable
    }

    func delete(id _: String) async throws {
        savedCalls += 1
    }

    func previewAudio(_ request: VoiceBlendPreviewRequest) async throws -> Data {
        previewed.append(request)
        while holdsResponse {
            try await Task.sleep(for: .milliseconds(10))
        }
        if let error {
            throw error
        }
        return audio
    }
}

private struct PlayerFailure: Error {}

@MainActor
final class VoiceBlendPreviewerTests: XCTestCase {
    private func makePreviewer(_ service: StubPreviewService) -> VoiceBlendPreviewer {
        VoiceBlendPreviewer(service: service, makePlayer: { _ in throw PlayerFailure() })
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func test_previewRequestMirrorsTheDraftWithoutAName() {
        var draft = VoiceBlendDraft()
        draft.components[0].weight = 0.75
        draft.components[1].weight = 0.254

        XCTAssertTrue(draft.isPreviewable)
        XCTAssertFalse(draft.isValid)
        XCTAssertEqual(draft.previewRequest, VoiceBlendPreviewRequest(components: ["af_bella", "af_sarah"], weights: [0.75, 0.25]))
    }

    func test_previewRequestEncodesOnlyVoicesAndWeights() throws {
        let data = try JSONEncoder().encode(VoiceBlendDraft().previewRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["components", "weights"])
    }

    func test_draftWithDuplicateVoicesIsNotPreviewable() {
        var draft = VoiceBlendDraft()
        draft.components[1].voice = draft.components[0].voice

        XCTAssertFalse(draft.isPreviewable)
    }

    func test_playRequestsTheDraftAndNeverSaves() async {
        let service = StubPreviewService()
        let previewer = makePreviewer(service)

        previewer.play(VoiceBlendDraft())
        await waitUntil { previewer.errorMessage != nil }

        XCTAssertEqual(service.previewed, [VoiceBlendDraft().previewRequest])
        XCTAssertEqual(service.savedCalls, 0)
    }

    func test_loadingPhaseIsStoppable() async {
        let service = StubPreviewService()
        service.holdsResponse = true
        let previewer = makePreviewer(service)

        previewer.toggle(VoiceBlendDraft())
        XCTAssertEqual(previewer.phase, .loading)
        XCTAssertTrue(previewer.isBusy)

        previewer.toggle(VoiceBlendDraft())
        service.holdsResponse = false
        XCTAssertEqual(previewer.phase, .idle)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(previewer.phase, .idle)
        XCTAssertNil(previewer.errorMessage)
    }

    func test_serviceFailureSurfacesTheMessageAndReturnsToIdle() async {
        let service = StubPreviewService()
        service.error = BackendAPIError.rejected(statusCode: 422, message: "Voice listed twice.")
        let previewer = makePreviewer(service)

        previewer.play(VoiceBlendDraft())
        await waitUntil { previewer.errorMessage != nil }

        XCTAssertEqual(previewer.phase, .idle)
        XCTAssertEqual(previewer.errorMessage, "Voice listed twice.")
    }

    func test_playerFailureReportsAPlaybackMessage() async {
        let previewer = makePreviewer(StubPreviewService())

        previewer.play(VoiceBlendDraft())
        await waitUntil { previewer.errorMessage != nil }

        XCTAssertEqual(previewer.phase, .idle)
        XCTAssertEqual(previewer.errorMessage, "Voqora couldn't play this preview.")
    }

    func test_resetClearsTheError() async {
        let service = StubPreviewService()
        service.error = BackendAPIError.unreachable
        let previewer = makePreviewer(service)
        previewer.play(VoiceBlendDraft())
        await waitUntil { previewer.errorMessage != nil }

        previewer.reset()

        XCTAssertNil(previewer.errorMessage)
    }

    func test_unpreviewableDraftDoesNotCallTheService() {
        let service = StubPreviewService()
        let previewer = makePreviewer(service)
        var draft = VoiceBlendDraft()
        draft.components[1].voice = draft.components[0].voice

        previewer.play(draft)

        XCTAssertEqual(previewer.phase, .idle)
        XCTAssertTrue(service.previewed.isEmpty)
    }
}
