import Combine
import Foundation

final class PodcastBriefModel: ObservableObject {
    enum State: Equatable {
        case editing
        case generating
        case failed(String)
    }

    @Published var brief: PodcastBrief {
        didSet {
            if case .failed = state, brief != oldValue {
                state = .editing
            }
        }
    }

    @Published private(set) var state: State = .editing
    @Published private(set) var showsIssues = false

    private let service: PodcastServing
    private let credential: @MainActor () -> LLMCredential?
    private let onScript: @MainActor (PodcastScriptResult) -> Void
    private var generation: Task<Void, Never>?

    init(
        brief: PodcastBrief,
        service: PodcastServing,
        credential: @escaping @MainActor () -> LLMCredential?,
        onScript: @escaping @MainActor (PodcastScriptResult) -> Void
    ) {
        self.brief = brief
        self.service = service
        self.credential = credential
        self.onScript = onScript
    }

    var needsProvider: Bool {
        credential() == nil
    }

    var isGenerating: Bool {
        state == .generating
    }

    func issues(blends: [PodcastVoiceBlend]) -> [PodcastBriefIssue] {
        brief.issues(blends: blends)
    }

    func generate(blends: [PodcastVoiceBlend]) {
        guard !isGenerating else { return }
        guard let credential = credential() else {
            state = .failed(AudiobookViewModel.missingProviderMessage)
            return
        }
        guard let request = brief.request(blends: blends) else {
            showsIssues = true
            state = .failed(brief.issues(blends: blends).first?.message ?? "Check the podcast details and try again.")
            return
        }
        showsIssues = false
        state = .generating
        VoqoraLog.info("Studio", "Podcast script requested", [
            "style": request.style.rawValue,
            "minutes": "\(request.minutes)",
            "hosts": "\(request.hosts.count)",
            "provider": credential.provider.rawValue,
        ])
        generation = Task { [weak self] in
            await self?.run(request, credential: credential)
        }
    }

    func cancel() {
        generation?.cancel()
        generation = nil
        if isGenerating {
            state = .editing
        }
    }

    private func run(_ request: PodcastScriptRequest, credential: LLMCredential) async {
        do {
            let result = try await service.writeScript(request, credential: credential)
            guard !Task.isCancelled else { return }
            state = .editing
            generation = nil
            onScript(result)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            VoqoraLog.warn("Studio", "Podcast script failed", ["failureCode": PodcastServiceError.logLabel(for: error)])
            state = .failed(error.localizedDescription)
            generation = nil
        }
    }
}
