import Combine
import SwiftUI

struct StudioLibraryHooks {
    let refresh: @MainActor () async -> Void
    let track: @MainActor (String) -> Void
    let announce: @MainActor (String) -> Void

    static func live(_ library: AudiobookViewModel) -> StudioLibraryHooks {
        StudioLibraryHooks(
            refresh: { [weak library] in await library?.refresh() },
            track: { [weak library] bookID in library?.subscribe(to: bookID) },
            announce: { [weak library] message in library?.showToast(message, kind: .success) }
        )
    }
}

final class PodcastScriptEditor: ObservableObject, Identifiable {
    enum RenderState: Equatable {
        case idle
        case rendering
        case rendered(PodcastRenderReceipt)
        case failed(String)
    }

    nonisolated static let autosaveDelayNanoseconds: UInt64 = 800_000_000

    let id: UUID
    let basedOnBookID: String?
    @Published var script: PodcastScript {
        didSet {
            guard script != oldValue else { return }
            hasUnsavedChanges = true
            if case .failed = renderState {
                renderState = .idle
            }
            scheduleAutosave()
        }
    }

    @Published private(set) var renderState: RenderState = .idle
    @Published private(set) var hasUnsavedChanges = false
    @Published var notice: String?

    private let store: StudioDraftStore
    private let service: PodcastServing
    private let library: StudioLibraryHooks
    private let autosaveDelay: UInt64
    private var autosaveTask: Task<Void, Never>?

    init(
        draft: PodcastDraft,
        store: StudioDraftStore,
        service: PodcastServing,
        library: StudioLibraryHooks,
        autosaveDelayNanoseconds: UInt64? = nil
    ) {
        id = draft.id
        basedOnBookID = draft.basedOnBookID
        script = draft.script
        self.store = store
        self.service = service
        self.library = library
        autosaveDelay = autosaveDelayNanoseconds ?? Self.autosaveDelayNanoseconds
    }

    var issues: [PodcastScriptIssue] {
        PodcastScriptValidator.issues(in: script)
    }

    var canRender: Bool {
        issues.isEmpty && renderState != .rendering
    }

    var canAddSpeaker: Bool {
        script.speakers.count < PodcastLimits.speakers.upperBound
    }

    var canRemoveSpeaker: Bool {
        script.speakers.count > PodcastLimits.speakers.lowerBound
    }

    var canAddTurn: Bool {
        script.turns.count < PodcastLimits.turns.upperBound
    }

    func addSpeaker(voice: String) {
        guard canAddSpeaker else { return }
        let id = script.nextSpeakerID()
        script.speakers.append(PodcastSpeaker(id: id, name: "Host \(script.speakers.count + 1)", voice: voice))
    }

    func removeSpeaker(id: String) {
        guard canRemoveSpeaker, let index = script.speakers.firstIndex(where: { $0.id == id }) else { return }
        var updated = script
        updated.speakers.remove(at: index)
        if let fallback = updated.speakers.first?.id {
            for turnIndex in updated.turns.indices where updated.turns[turnIndex].speakerID == id {
                updated.turns[turnIndex].speakerID = fallback
            }
        }
        script = updated
    }

    @discardableResult
    func insertTurn(after turnID: PodcastTurn.ID?) -> PodcastTurn.ID? {
        guard canAddTurn else { return nil }
        let position = turnID.flatMap { id in script.turns.firstIndex { $0.id == id } }
        let speakerID = nextSpeaker(after: position)
        let turn = PodcastTurn(speakerID: speakerID, text: "")
        let insertAt = position.map { $0 + 1 } ?? script.turns.count
        script.turns.insert(turn, at: insertAt)
        return turn.id
    }

    func deleteTurn(_ turnID: PodcastTurn.ID) {
        script.turns.removeAll { $0.id == turnID }
    }

    func moveTurns(fromOffsets source: IndexSet, toOffset destination: Int) {
        var turns = script.turns
        turns.move(fromOffsets: source, toOffset: destination)
        script.turns = turns
    }

    func moveTurn(_ turnID: PodcastTurn.ID, by offset: Int) {
        guard let index = script.turns.firstIndex(where: { $0.id == turnID }) else { return }
        let target = index + offset
        guard script.turns.indices.contains(target) else { return }
        script.turns.swapAt(index, target)
    }

    func setChapter(_ title: String?, forTurn turnID: PodcastTurn.ID) {
        guard let index = script.turns.firstIndex(where: { $0.id == turnID }) else { return }
        script.turns[index].section = title
    }

    @discardableResult
    func save() -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        let saved = store.save(PodcastDraft(id: id, script: script, updatedAt: Date(), basedOnBookID: basedOnBookID))
        if saved {
            hasUnsavedChanges = false
        }
        return saved
    }

    func render() async {
        guard renderState != .rendering else { return }
        let problems = issues
        guard problems.isEmpty else {
            renderState = .failed(problems[0].message)
            return
        }
        save()
        renderState = .rendering
        do {
            let receipt = try await service.render(script.normalizedForRender())
            VoqoraLog.info("Studio", "Podcast render queued", [
                "bookID": receipt.bookID,
                "turns": "\(receipt.turnCount)",
                "speakers": "\(receipt.speakers.count)",
            ])
            UsageStatsStore.shared.recordPodcastRender(speakers: receipt.speakers.count, audioSeconds: receipt.estimatedAudioSeconds)
            MetricsService.shared.trackPodcastRender(speakers: receipt.speakers.count, audioSeconds: receipt.estimatedAudioSeconds, ok: true)
            renderState = .rendered(receipt)
            await library.refresh()
            library.track(receipt.bookID)
            library.announce("Rendering \u{201C}\(receipt.title)\u{201D}. It's in your Library.")
        } catch is CancellationError {
            renderState = .idle
        } catch {
            MetricsService.shared.trackPodcastRender(speakers: script.speakers.count, audioSeconds: nil, ok: false)
            VoqoraLog.warn("Studio", "Podcast render failed", ["failureCode": PodcastServiceError.logLabel(for: error)])
            renderState = .failed(error.localizedDescription)
        }
    }

    func dismissRenderResult() {
        if renderState != .rendering {
            renderState = .idle
        }
    }

    private func nextSpeaker(after position: Int?) -> String {
        let ids = script.speakers.map(\.id)
        guard let first = ids.first else { return "" }
        guard let position, let current = ids.firstIndex(of: script.turns[position].speakerID) else {
            let lastSpeaker = script.turns.last?.speakerID
            let lastIndex = lastSpeaker.flatMap { ids.firstIndex(of: $0) }
            return lastIndex.map { ids[($0 + 1) % ids.count] } ?? first
        }
        return ids[(current + 1) % ids.count]
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let delay = autosaveDelay
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.stageAutosave()
        }
    }

    private func stageAutosave() {
        autosaveTask = nil
        store.autosave(PodcastDraft(id: id, script: script, updatedAt: Date(), basedOnBookID: basedOnBookID))
        hasUnsavedChanges = false
    }
}
