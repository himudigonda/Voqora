import AVFoundation
import Combine
import Foundation

final class VoiceBlendPreviewer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum Phase: Equatable {
        case idle
        case loading
        case playing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var errorMessage: String?

    private let service: any VoiceBlendServing
    private let makePlayer: (Data) throws -> AVAudioPlayer
    private var player: AVAudioPlayer?
    private var loadTask: Task<Void, Never>?

    init(
        service: (any VoiceBlendServing)? = nil,
        makePlayer: @escaping (Data) throws -> AVAudioPlayer = { try AVAudioPlayer(data: $0) }
    ) {
        self.service = service ?? VoiceBlendService()
        self.makePlayer = makePlayer
        super.init()
    }

    var isBusy: Bool {
        phase != .idle
    }

    func toggle(_ draft: VoiceBlendDraft) {
        if isBusy {
            stop()
        } else {
            play(draft)
        }
    }

    func play(_ draft: VoiceBlendDraft) {
        stop()
        errorMessage = nil
        guard draft.isPreviewable else { return }
        let request = draft.previewRequest
        phase = .loading
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await service.previewAudio(request)
                guard !Task.isCancelled, phase == .loading else { return }
                start(data)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, phase == .loading else { return }
                phase = .idle
                VoqoraLog.warn("VoiceBlendPreviewer", "Blend preview failed", ["status": BackendAPIError.logLabel(for: error)])
                errorMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        player?.stop()
        player = nil
        phase = .idle
    }

    func reset() {
        stop()
        errorMessage = nil
    }

    private func start(_ data: Data) {
        do {
            let newPlayer = try makePlayer(data)
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            guard newPlayer.play() else { throw BackendAPIError.invalidResponse }
            player = newPlayer
            phase = .playing
        } catch {
            VoqoraLog.warn("VoiceBlendPreviewer", "Blend preview playback failed", ["failureCode": "blend_preview_playback_failed"])
            phase = .idle
            errorMessage = "Voqora couldn't play this preview."
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully _: Bool) {
        let finishedID = ObjectIdentifier(finished)
        Task { @MainActor in
            guard let player = self.player, ObjectIdentifier(player) == finishedID else { return }
            self.player = nil
            self.phase = .idle
        }
    }
}
