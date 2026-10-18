import Foundation
@testable import Voqora
import XCTest

@MainActor
final class StudioViewModelTests: XCTestCase {
    private var url: URL!
    private var service: StudioFakePodcastService!
    private var library: StudioLibrarySpy!

    override func setUp() {
        super.setUp()
        url = StudioFixtures.temporaryURL()
        service = StudioFakePodcastService()
        library = StudioLibrarySpy()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        super.tearDown()
    }

    private func makeStudio(connected: Bool = true) -> StudioViewModel {
        StudioViewModel(
            providers: StudioFixtures.providers(connected: connected),
            library: library.hooks,
            service: service,
            drafts: StudioDraftStore(storageURL: url)
        )
    }

    private func briefModel(in studio: StudioViewModel, text: String = "Notes about the moon.") throws -> PodcastBriefModel {
        studio.startNewPodcast(source: .text(text))
        return try XCTUnwrap(studio.briefModel)
    }

    func test_newPodcastPrefillsTheSource() throws {
        let studio = makeStudio()

        studio.startNewPodcast(source: .book("book-1"))

        XCTAssertEqual(studio.route, .newPodcast)
        let brief = try XCTUnwrap(studio.briefModel?.brief)
        XCTAssertEqual(brief.sourceKind, .library)
        XCTAssertEqual(brief.bookID, "book-1")
    }

    func test_generateWithoutProviderShowsFriendlyMessage() throws {
        let studio = makeStudio(connected: false)
        let model = try briefModel(in: studio)

        XCTAssertTrue(model.needsProvider)
        model.generate(blends: [])

        XCTAssertEqual(model.state, .failed(AudiobookViewModel.missingProviderMessage))
        XCTAssertTrue(service.writeRequests.isEmpty)
    }

    func test_generateWithInvalidBriefShowsFirstIssue() throws {
        let studio = makeStudio()
        let model = try briefModel(in: studio, text: "  ")

        model.generate(blends: [])

        XCTAssertEqual(model.state, .failed(PodcastBriefIssue.missingText.message))
        XCTAssertTrue(model.showsIssues)
        XCTAssertTrue(service.writeRequests.isEmpty)
    }

    func test_generatedScriptOpensInTheEditorAndIsSaved() async throws {
        service.scriptResult = .success(StudioFixtures.result(truncated: true))
        let studio = makeStudio()
        let model = try briefModel(in: studio)

        model.generate(blends: [])
        XCTAssertTrue(model.isGenerating)
        await StudioFixtures.waitUntil { studio.route == .editor }

        XCTAssertEqual(service.writeRequests.first?.source, .text("Notes about the moon."))
        XCTAssertEqual(service.credentials.first?.provider, .ollama)
        let editor = try XCTUnwrap(studio.editor)
        XCTAssertEqual(editor.script.title, "Night Sky")
        XCTAssertNotNil(editor.notice)
        XCTAssertNil(studio.briefModel)
        XCTAssertEqual(studio.drafts.drafts.map(\.id), [editor.id])
    }

    func test_generationFailureKeepsTheBrief() async throws {
        service.scriptResult = .failure(PodcastServiceError.busy("Voqora is already writing podcast scripts. Try again shortly."))
        let studio = makeStudio()
        let model = try briefModel(in: studio)

        model.generate(blends: [])
        await StudioFixtures.waitUntil { !model.isGenerating }

        XCTAssertEqual(model.state, .failed("Voqora is already writing podcast scripts. Try again shortly."))
        XCTAssertEqual(studio.route, .newPodcast)
        model.brief.minutes = 5
        XCTAssertEqual(model.state, .editing)
    }

    func test_cancelStopsGeneration() async throws {
        service.holdsScript = true
        service.scriptResult = .success(StudioFixtures.result())
        let studio = makeStudio()
        let model = try briefModel(in: studio)

        model.generate(blends: [])
        await StudioFixtures.waitUntil { !service.writeRequests.isEmpty }
        model.cancel()
        service.holdsScript = false
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(model.state, .editing)
        XCTAssertEqual(studio.route, .newPodcast)
        XCTAssertNil(studio.editor)
    }

    func test_blankScriptOpensASavedEditor() throws {
        let studio = makeStudio()

        studio.startBlankScript()

        let editor = try XCTUnwrap(studio.editor)
        XCTAssertEqual(studio.route, .editor)
        XCTAssertEqual(editor.script.speakers.count, 2)
        XCTAssertEqual(editor.script.turns.count, 1)
        XCTAssertEqual(studio.drafts.drafts.count, 1)
    }

    func test_openingARenderedPodcastMakesACopy() async throws {
        service.storedScript = .success(StudioFixtures.script(turns: 3))
        let studio = makeStudio()

        studio.openRenderedPodcast(bookID: "book-7")
        await StudioFixtures.waitUntil { studio.openingBookID == nil }

        XCTAssertEqual(service.requestedScriptIDs, ["book-7"])
        let editor = try XCTUnwrap(studio.editor)
        XCTAssertEqual(editor.basedOnBookID, "book-7")
        XCTAssertEqual(editor.script.turns.count, 3)
        XCTAssertEqual(studio.drafts.drafts.first?.basedOnBookID, "book-7")
    }

    func test_openingAMissingPodcastShowsNotice() async {
        let studio = makeStudio()

        studio.openRenderedPodcast(bookID: "book-7")
        await StudioFixtures.waitUntil { studio.openingBookID == nil }

        XCTAssertEqual(studio.notice, "Podcast not found.")
        XCTAssertNil(studio.editor)
        XCTAssertEqual(studio.route, .home)
    }

    func test_goingHomeSavesUnsavedEdits() throws {
        let studio = makeStudio()
        studio.startBlankScript()
        let editor = try XCTUnwrap(studio.editor)
        editor.script.title = "Kept"

        studio.goHome()

        XCTAssertEqual(studio.route, .home)
        XCTAssertNil(studio.editor)
        XCTAssertEqual(studio.drafts.draft(withID: editor.id)?.script.title, "Kept")
    }

    func test_deletingTheOpenDraftClosesTheEditor() throws {
        let studio = makeStudio()
        studio.startBlankScript()
        let editor = try XCTUnwrap(studio.editor)

        studio.deleteDraft(editor.id)

        XCTAssertNil(studio.editor)
        XCTAssertEqual(studio.route, .home)
        XCTAssertTrue(studio.drafts.drafts.isEmpty)
    }

    func test_loadBlendsKeepsCatalog() async {
        service.blends = [PodcastVoiceBlend(id: "blend:1", name: "Warm", lang: "en-us")]
        let studio = makeStudio()

        await studio.loadBlends()

        XCTAssertEqual(studio.blends.map(\.name), ["Warm"])
    }
}
