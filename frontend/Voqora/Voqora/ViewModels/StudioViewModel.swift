import Combine
import Foundation

final class StudioViewModel: ObservableObject {
    struct Redirect: Equatable {
        let key: String
        let issuedAt: Date
    }

    nonisolated static let redirectLifetime: TimeInterval = 10
    nonisolated static let parkedScriptMessage = "Script ready. Open it from Scripts."

    @Published private(set) var editor: PodcastScriptEditor?
    @Published private(set) var briefModel: PodcastBriefModel?
    @Published private(set) var blends: [PodcastVoiceBlend] = []
    @Published private(set) var openingBookID: String?
    @Published private(set) var redirect: Redirect?
    @Published var notice: String?

    var currentTab: @MainActor () -> String? = { nil }

    let drafts: StudioDraftStore
    let previewer: StudioVoicePreviewer
    let providers: LLMProviderStore
    private let service: PodcastServing
    private let library: StudioLibraryHooks

    init(
        providers: LLMProviderStore,
        library: StudioLibraryHooks,
        service: PodcastServing? = nil,
        drafts: StudioDraftStore? = nil
    ) {
        let resolvedService = service ?? PodcastService()
        self.service = resolvedService
        self.providers = providers
        self.library = library
        self.drafts = drafts ?? StudioDraftStore()
        previewer = StudioVoicePreviewer(service: resolvedService)
    }

    func loadBlends() async {
        do {
            blends = try await service.voiceBlends()
        } catch {
            VoqoraLog.info("Studio", "Voice blends unavailable", ["failureCode": PodcastServiceError.logLabel(for: error)])
        }
    }

    func ensureBriefModel() {
        guard briefModel == nil else { return }
        briefModel = makeBriefModel(brief: PodcastBrief())
    }

    func startNewPodcast(source: PodcastSource? = nil) {
        previewer.stop()
        briefModel?.cancel()
        closeEditorSaving()
        var brief = PodcastBrief()
        switch source {
        case let .book(bookID):
            brief.sourceKind = .library
            brief.bookID = bookID
        case let .text(text):
            brief.sourceKind = .text
            brief.text = text
        case nil:
            break
        }
        briefModel = makeBriefModel(brief: brief)
        issueRedirect(TabKey.createPodcast)
    }

    func startBlankScript() {
        let voices = StudioVoiceCatalog.defaultVoices(for: .englishUS)
        let script = PodcastScript.blank(
            firstVoice: voices.first ?? "af_bella",
            secondVoice: voices.dropFirst().first ?? voices.first ?? "am_adam"
        )
        open(PodcastDraft(script: script))
    }

    func open(_ draft: PodcastDraft, ifStillOn origin: String? = nil) {
        guard isStillOn(origin) else {
            park(draft)
            return
        }
        previewer.stop()
        closeEditorSaving()
        let editor = PodcastScriptEditor(draft: draft, store: drafts, service: service, library: library)
        if drafts.draft(withID: draft.id) == nil {
            editor.save()
        }
        self.editor = editor
        briefModel?.cancel()
        briefModel = nil
        issueRedirect(TabKey.createScriptEditor)
    }

    func openRenderedPodcast(bookID: String) {
        guard openingBookID == nil else { return }
        notice = nil
        openingBookID = bookID
        Task { [weak self] in
            await self?.loadRenderedScript(bookID: bookID)
        }
    }

    func deleteDraft(_ id: UUID) {
        if editor?.id == id {
            editor = nil
        }
        drafts.delete(id)
    }

    func closeEditor() {
        previewer.stop()
        closeEditorSaving()
    }

    func flushForTermination() {
        closeEditorSaving()
        drafts.flush()
    }

    func eraseAllDrafts() throws {
        editor = nil
        try drafts.eraseAll()
    }

    func takeRedirect(now: Date = Date()) -> String? {
        guard let redirect else { return nil }
        self.redirect = nil
        return now.timeIntervalSince(redirect.issuedAt) <= Self.redirectLifetime ? redirect.key : nil
    }

    private func isStillOn(_ origin: String?) -> Bool {
        guard let origin else { return true }
        return TabKey.canonical(currentTab()) == origin
    }

    private func park(_ draft: PodcastDraft) {
        drafts.save(draft)
        library.announce(Self.parkedScriptMessage)
    }

    private func issueRedirect(_ key: String) {
        redirect = Redirect(key: key, issuedAt: Date())
    }

    private func makeBriefModel(brief: PodcastBrief) -> PodcastBriefModel {
        PodcastBriefModel(
            brief: brief,
            service: service,
            credential: { [weak self] in self?.providers.activeCredential },
            onScript: { [weak self] result in self?.openGenerated(result) }
        )
    }

    private func closeEditorSaving() {
        if let editor, editor.hasUnsavedChanges {
            editor.save()
        }
        editor = nil
    }

    private func openGenerated(_ result: PodcastScriptResult) {
        let draft = PodcastDraft(script: result.script)
        open(draft, ifStillOn: TabKey.createPodcast)
        if result.sourceTruncated, editor?.id == draft.id {
            editor?.notice = "The source was long, so Voqora used its first part."
        }
    }

    private func loadRenderedScript(bookID: String) async {
        defer { openingBookID = nil }
        do {
            let script = try await service.script(forPodcast: bookID)
            let draft = PodcastDraft(script: script, basedOnBookID: bookID)
            open(draft, ifStillOn: TabKey.createScripts)
            if editor?.id == draft.id {
                editor?.notice = "Editing a copy. Rendering makes a new podcast and keeps the original."
            }
        } catch {
            VoqoraLog.warn("Studio", "Podcast script unavailable", ["bookID": bookID, "failureCode": PodcastServiceError.logLabel(for: error)])
            notice = error.localizedDescription
        }
    }
}
