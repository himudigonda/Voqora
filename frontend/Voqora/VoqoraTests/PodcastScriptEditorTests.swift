import Foundation
@testable import Voqora
import XCTest

@MainActor
final class PodcastScriptEditorTests: XCTestCase {
    private var url: URL!
    private var store: StudioDraftStore!
    private var service: StudioFakePodcastService!
    private var library: StudioLibrarySpy!

    override func setUp() {
        super.setUp()
        url = StudioFixtures.temporaryURL()
        store = StudioDraftStore(storageURL: url)
        service = StudioFakePodcastService()
        library = StudioLibrarySpy()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        super.tearDown()
    }

    private func makeEditor(script: PodcastScript? = nil, autosave: UInt64 = 60_000_000_000) -> PodcastScriptEditor {
        PodcastScriptEditor(
            draft: PodcastDraft(script: script ?? StudioFixtures.script()),
            store: store,
            service: service,
            library: library.hooks,
            autosaveDelayNanoseconds: autosave
        )
    }

    func test_insertTurnAlternatesSpeakersAndPlacesBelow() throws {
        let editor = makeEditor()
        let first = editor.script.turns[0].id

        let inserted = try XCTUnwrap(editor.insertTurn(after: first))

        XCTAssertEqual(editor.script.turns.count, 3)
        XCTAssertEqual(editor.script.turns[1].id, inserted)
        XCTAssertEqual(editor.script.turns[1].speakerID, "host_2")
        XCTAssertEqual(editor.script.turns[1].pauseAfterSeconds, PodcastLimits.defaultPauseSeconds)
        XCTAssertTrue(editor.hasUnsavedChanges)
    }

    func test_appendTurnFollowsTheLastSpeaker() {
        let editor = makeEditor()

        editor.insertTurn(after: nil)

        XCTAssertEqual(editor.script.turns.last?.speakerID, "host_1")
    }

    func test_turnLimitBlocksInsert() {
        let editor = makeEditor(script: StudioFixtures.script(turns: PodcastLimits.turns.upperBound))

        XCTAssertFalse(editor.canAddTurn)
        XCTAssertNil(editor.insertTurn(after: nil))
        XCTAssertEqual(editor.script.turns.count, PodcastLimits.turns.upperBound)
    }

    func test_deleteAndMoveTurns() {
        let editor = makeEditor(script: StudioFixtures.script(turns: 3))
        let ids = editor.script.turns.map(\.id)

        editor.moveTurns(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(editor.script.turns.map(\.id), [ids[2], ids[0], ids[1]])

        editor.moveTurn(ids[2], by: 1)
        XCTAssertEqual(editor.script.turns.map(\.id), [ids[0], ids[2], ids[1]])

        editor.moveTurn(ids[0], by: -1)
        XCTAssertEqual(editor.script.turns.map(\.id), [ids[0], ids[2], ids[1]])

        editor.deleteTurn(ids[2])
        XCTAssertEqual(editor.script.turns.map(\.id), [ids[0], ids[1]])
    }

    func test_removingASpeakerMovesTheirTurnsToTheFirstSpeaker() {
        let editor = makeEditor(script: StudioFixtures.script(turns: 4))

        editor.removeSpeaker(id: "host_1")

        XCTAssertEqual(editor.script.speakers.map(\.id), ["host_2"])
        XCTAssertEqual(Set(editor.script.turns.map(\.speakerID)), ["host_2"])
        XCTAssertFalse(editor.canRemoveSpeaker)
        editor.removeSpeaker(id: "host_2")
        XCTAssertEqual(editor.script.speakers.count, 1)
    }

    func test_speakerLimit() {
        let editor = makeEditor()
        editor.addSpeaker(voice: "af_sarah")
        editor.addSpeaker(voice: "am_puck")

        XCTAssertEqual(editor.script.speakers.map(\.id), ["host_1", "host_2", "host_3", "host_4"])
        XCTAssertFalse(editor.canAddSpeaker)
        editor.addSpeaker(voice: "af_kore")
        XCTAssertEqual(editor.script.speakers.count, PodcastLimits.speakers.upperBound)
    }

    func test_chapterCanBeStartedAndRemoved() {
        let editor = makeEditor()
        let id = editor.script.turns[1].id

        editor.setChapter("", forTurn: id)
        XCTAssertEqual(editor.script.turns[1].section, "")
        editor.setChapter(nil, forTurn: id)
        XCTAssertNil(editor.script.turns[1].section)
    }

    func test_saveWritesTheDraftAndClearsUnsavedFlag() {
        let editor = makeEditor()
        editor.script.title = "Edited"

        XCTAssertTrue(editor.save())

        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertEqual(store.draft(withID: editor.id)?.script.title, "Edited")
    }

    func test_autosaveRunsAfterADelay() async {
        let editor = makeEditor(autosave: 1_000_000)

        editor.script.title = "Autosaved"
        await StudioFixtures.waitUntil { !editor.hasUnsavedChanges }

        XCTAssertEqual(store.draft(withID: editor.id)?.script.title, "Autosaved")
    }

    func test_invalidScriptDoesNotRender() async {
        var script = StudioFixtures.script()
        script.turns[0].text = " "
        let editor = makeEditor(script: script)

        await editor.render()

        XCTAssertFalse(editor.canRender)
        XCTAssertEqual(editor.renderState, .failed(PodcastScriptIssue.emptyTurn(turn: 0).message))
        XCTAssertTrue(service.renderedScripts.isEmpty)
    }

    func test_renderSendsNormalizedScriptAndUpdatesLibrary() async {
        var script = StudioFixtures.script()
        script.turns[0].text = "  Hello.  "
        service.renderResult = .success(StudioFixtures.receipt(bookID: "book-9"))
        let editor = makeEditor(script: script)

        await editor.render()

        XCTAssertEqual(service.renderedScripts.first?.turns[0].text, "Hello.")
        XCTAssertEqual(editor.renderState, .rendered(StudioFixtures.receipt(bookID: "book-9")))
        XCTAssertEqual(library.refreshCount, 1)
        XCTAssertEqual(library.tracked, ["book-9"])
        XCTAssertEqual(library.announcements.count, 1)
        XCTAssertNotNil(store.draft(withID: editor.id))
    }

    func test_renderFailureShowsMessageAndClearsOnEdit() async {
        service.renderResult = .failure(PodcastServiceError.tooLarge("This podcast would exceed Voqora's 24-hour narration limit."))
        let editor = makeEditor()

        await editor.render()
        XCTAssertEqual(editor.renderState, .failed("This podcast would exceed Voqora's 24-hour narration limit."))
        XCTAssertTrue(library.tracked.isEmpty)

        editor.script.title = "Shorter"
        XCTAssertEqual(editor.renderState, .idle)
    }
}
