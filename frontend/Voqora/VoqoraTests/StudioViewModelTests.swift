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

    private func makeStudio(connected: Bool = true, tab: String? = TabKey.createPodcast) -> StudioViewModel {
        let studio = StudioViewModel(
            providers: StudioFixtures.providers(connected: connected),
            library: library.hooks,
            service: service,
            drafts: StudioDraftStore(storageURL: url)
        )
        studio.currentTab = { tab }
        return studio
    }

    private func briefModel(in studio: StudioViewModel, text: String = "Notes about the moon.") throws -> PodcastBriefModel {
        studio.startNewPodcast(source: .text(text))
        return try XCTUnwrap(studio.briefModel)
    }

    func test_newPodcastPrefillsTheSource() throws {
        let studio = makeStudio()

        studio.startNewPodcast(source: .book("book-1"))

        XCTAssertEqual(studio.takeRedirect(), TabKey.createPodcast)
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
        await StudioFixtures.waitUntil { studio.editor != nil }

        XCTAssertEqual(service.writeRequests.first?.source, .text("Notes about the moon."))
        XCTAssertEqual(service.credentials.first?.provider, .ollama)
        let editor = try XCTUnwrap(studio.editor)
        XCTAssertEqual(editor.script.title, "Night Sky")
        XCTAssertNotNil(editor.notice)
        XCTAssertNil(studio.briefModel)
        XCTAssertEqual(studio.takeRedirect(), TabKey.createScriptEditor)
        XCTAssertEqual(studio.drafts.drafts.map(\.id), [editor.id])
    }

    func test_generatedScriptStaysParkedWhenTheUserLeftThePodcastPage() async throws {
        service.scriptResult = .success(StudioFixtures.result())
        let studio = makeStudio(tab: TabKey.createAudiobook)
        let model = try briefModel(in: studio)
        _ = studio.takeRedirect()

        model.generate(blends: [])
        await StudioFixtures.waitUntil { !studio.drafts.drafts.isEmpty }

        XCTAssertNil(studio.editor)
        XCTAssertNil(studio.redirect)
        XCTAssertEqual(studio.drafts.drafts.first?.script.title, "Night Sky")
        XCTAssertEqual(library.announcements, [StudioViewModel.parkedScriptMessage])
    }

    func test_parkedScriptDoesNotReplaceTheOpenEditor() throws {
        let studio = makeStudio(tab: TabKey.createScriptEditor)
        studio.startBlankScript()
        let openEditor = try XCTUnwrap(studio.editor)
        _ = studio.takeRedirect()

        studio.open(PodcastDraft(script: StudioFixtures.script(turns: 4)), ifStillOn: TabKey.createPodcast)

        XCTAssertEqual(studio.editor?.id, openEditor.id)
        XCTAssertNil(studio.redirect)
        XCTAssertEqual(studio.drafts.drafts.count, 2)
    }

    func test_renderedScriptLoadedAfterLeavingScriptsOnlyAnnounces() async {
        service.storedScript = .success(StudioFixtures.script(turns: 3))
        let studio = makeStudio(tab: TabKey.createAudiobook)

        studio.openRenderedPodcast(bookID: "book-7")
        await StudioFixtures.waitUntil { studio.openingBookID == nil }

        XCTAssertNil(studio.editor)
        XCTAssertNil(studio.redirect)
        XCTAssertEqual(studio.drafts.drafts.first?.basedOnBookID, "book-7")
        XCTAssertEqual(library.announcements, [StudioViewModel.parkedScriptMessage])
    }

    func test_renderedScriptOpensWhenTheUserIsStillOnScripts() async {
        service.storedScript = .success(StudioFixtures.script(turns: 3))
        let studio = makeStudio(tab: TabKey.createScripts)

        studio.openRenderedPodcast(bookID: "book-7")
        await StudioFixtures.waitUntil { studio.openingBookID == nil }

        XCTAssertNotNil(studio.editor)
        XCTAssertEqual(studio.takeRedirect(), TabKey.createScriptEditor)
        XCTAssertTrue(library.announcements.isEmpty)
    }

    func test_generationFailureKeepsTheBrief() async throws {
        service.scriptResult = .failure(PodcastServiceError.busy("Voqora is already writing podcast scripts. Try again shortly."))
        let studio = makeStudio()
        let model = try briefModel(in: studio)

        model.generate(blends: [])
        await StudioFixtures.waitUntil { !model.isGenerating }

        XCTAssertEqual(model.state, .failed("Voqora is already writing podcast scripts. Try again shortly."))
        XCTAssertNotNil(studio.briefModel)
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
        XCTAssertNotNil(studio.briefModel)
        XCTAssertNil(studio.editor)
    }

    func test_openingAScriptCancelsAPendingGeneration() async throws {
        service.holdsScript = true
        service.scriptResult = .success(StudioFixtures.result())
        let studio = makeStudio()
        let model = try briefModel(in: studio)

        model.generate(blends: [])
        await StudioFixtures.waitUntil { !service.writeRequests.isEmpty }
        studio.startBlankScript()
        service.holdsScript = false
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertFalse(model.isGenerating)
        XCTAssertEqual(studio.editor?.script.title, "Untitled Script")
        XCTAssertEqual(studio.drafts.drafts.count, 1)
    }

    func test_blankScriptOpensASavedEditor() throws {
        let studio = makeStudio()

        studio.startBlankScript()

        let editor = try XCTUnwrap(studio.editor)
        XCTAssertEqual(studio.takeRedirect(), TabKey.createScriptEditor)
        XCTAssertEqual(editor.script.speakers.count, 2)
        XCTAssertEqual(editor.script.turns.count, 1)
        XCTAssertEqual(studio.drafts.drafts.count, 1)
    }

    func test_openingARenderedPodcastMakesACopy() async throws {
        service.storedScript = .success(StudioFixtures.script(turns: 3))
        let studio = makeStudio(tab: TabKey.createScripts)

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
    }

    func test_closingTheEditorSavesUnsavedEdits() throws {
        let studio = makeStudio()
        studio.startBlankScript()
        let editor = try XCTUnwrap(studio.editor)
        editor.script.title = "Kept"

        studio.closeEditor()

        XCTAssertNil(studio.editor)
        XCTAssertEqual(studio.drafts.draft(withID: editor.id)?.script.title, "Kept")
    }

    func test_flushForTerminationPersistsPendingEditsToDisk() throws {
        let studio = makeStudio()
        studio.startBlankScript()
        let editor = try XCTUnwrap(studio.editor)
        editor.script.title = "Before Quit"

        studio.flushForTermination()

        XCTAssertEqual(StudioDraftStore(storageURL: url).draft(withID: editor.id)?.script.title, "Before Quit")
    }

    func test_eraseAllDraftsClosesTheEditorAndRemovesTheFile() throws {
        let studio = makeStudio()
        studio.startBlankScript()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try studio.eraseAllDrafts()

        XCTAssertNil(studio.editor)
        XCTAssertTrue(studio.drafts.drafts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_deletingTheOpenDraftClosesTheEditor() throws {
        let studio = makeStudio()
        studio.startBlankScript()
        let editor = try XCTUnwrap(studio.editor)

        studio.deleteDraft(editor.id)

        XCTAssertNil(studio.editor)
        XCTAssertTrue(studio.drafts.drafts.isEmpty)
    }

    func test_redirectIsTakenOnceAndExpires() {
        let studio = makeStudio()

        studio.startNewPodcast()
        XCTAssertEqual(studio.takeRedirect(), TabKey.createPodcast)
        XCTAssertNil(studio.takeRedirect())

        studio.startNewPodcast()
        let later = Date().addingTimeInterval(StudioViewModel.redirectLifetime + 1)
        XCTAssertNil(studio.takeRedirect(now: later))
        XCTAssertNil(studio.redirect)
    }

    func test_ensureBriefModelKeepsTheExistingBrief() throws {
        let studio = makeStudio()

        studio.ensureBriefModel()
        let first = try XCTUnwrap(studio.briefModel)
        first.brief.minutes = 11
        studio.ensureBriefModel()

        XCTAssertTrue(studio.briefModel === first)
        XCTAssertEqual(studio.briefModel?.brief.minutes, 11)
    }

    func test_loadBlendsKeepsCatalog() async {
        service.blends = [PodcastVoiceBlend(id: "blend:1", name: "Warm", lang: "en-us")]
        let studio = makeStudio()

        await studio.loadBlends()

        XCTAssertEqual(studio.blends.map(\.name), ["Warm"])
    }
}
