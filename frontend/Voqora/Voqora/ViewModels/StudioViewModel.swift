import Combine
import Foundation

final class StudioViewModel: ObservableObject {
    enum Route: Equatable {
        case home
        case newPodcast
        case editor
    }

    @Published private(set) var route: Route = .home
    @Published private(set) var editor: PodcastScriptEditor?
    @Published private(set) var briefModel: PodcastBriefModel?
    @Published private(set) var blends: [PodcastVoiceBlend] = []
    @Published private(set) var openingBookID: String?
    @Published var notice: String?

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

    func startNewPodcast(source: PodcastSource? = nil) {
        previewer.stop()
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
        briefModel = PodcastBriefModel(
            brief: brief,
            service: service,
            credential: { [weak self] in self?.providers.activeCredential },
            onScript: { [weak self] result in self?.openGenerated(result) }
        )
        route = .newPodcast
    }

    func startBlankScript() {
        let voices = StudioVoiceCatalog.defaultVoices(for: .englishUS)
        let script = PodcastScript.blank(
            firstVoice: voices.first ?? "af_bella",
            secondVoice: voices.dropFirst().first ?? voices.first ?? "am_adam"
        )
        open(PodcastDraft(script: script))
    }

    func open(_ draft: PodcastDraft) {
        previewer.stop()
        closeEditorSaving()
        let editor = PodcastScriptEditor(draft: draft, store: drafts, service: service, library: library)
        if drafts.draft(withID: draft.id) == nil {
            editor.save()
        }
        self.editor = editor
        briefModel = nil
        route = .editor
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
            route = .home
        }
        drafts.delete(id)
    }

    func goHome() {
        previewer.stop()
        briefModel?.cancel()
        briefModel = nil
        closeEditorSaving()
        route = .home
    }

    private func closeEditorSaving() {
        if let editor, editor.hasUnsavedChanges {
            editor.save()
        }
        editor = nil
    }

    private func openGenerated(_ result: PodcastScriptResult) {
        open(PodcastDraft(script: result.script))
        if result.sourceTruncated {
            editor?.notice = "The source was long, so Voqora used its first part."
        }
    }

    private func loadRenderedScript(bookID: String) async {
        defer { openingBookID = nil }
        do {
            let script = try await service.script(forPodcast: bookID)
            open(PodcastDraft(script: script, basedOnBookID: bookID))
            editor?.notice = "Editing a copy. Rendering makes a new podcast and keeps the original."
        } catch {
            VoqoraLog.warn("Studio", "Podcast script unavailable", ["bookID": bookID, "failureCode": PodcastServiceError.logLabel(for: error)])
            notice = error.localizedDescription
        }
    }
}
