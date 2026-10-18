import AVFoundation
import Combine
import Foundation

final class StudioVoicePreviewer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingVoice: String?
    @Published private(set) var loadingVoice: String?
    @Published private(set) var errorMessage: String?

    private let service: PodcastServing
    private var player: AVAudioPlayer?
    private var loadTask: Task<Void, Never>?

    init(service: PodcastServing) {
        self.service = service
        super.init()
    }

    func toggle(voice: String) {
        if playingVoice == voice || loadingVoice == voice {
            stop()
            return
        }
        play(voice: voice)
    }

    func play(voice: String) {
        stop()
        errorMessage = nil
        guard !voice.isEmpty else { return }
        if StudioVoiceCatalog.isBundledSample(voice), let url = Bundle.main.url(forResource: voice, withExtension: "wav") {
            start(voice: voice) { try AVAudioPlayer(contentsOf: url) }
            return
        }
        loadingVoice = voice
        let sentence = DashboardViewModel.sampleSentence(forVoice: voice)
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await service.previewAudio(text: sentence, voice: voice)
                guard !Task.isCancelled, loadingVoice == voice else { return }
                loadingVoice = nil
                start(voice: voice) { try AVAudioPlayer(data: data) }
            } catch is CancellationError {
                return
            } catch {
                guard loadingVoice == voice else { return }
                loadingVoice = nil
                VoqoraLog.warn("StudioVoicePreviewer", "Voice preview failed", ["failureCode": PodcastServiceError.logLabel(for: error)])
                errorMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        loadingVoice = nil
        player?.stop()
        player = nil
        playingVoice = nil
    }

    private func start(voice: String, makePlayer: () throws -> AVAudioPlayer) {
        do {
            let newPlayer = try makePlayer()
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            newPlayer.play()
            player = newPlayer
            playingVoice = voice
        } catch {
            VoqoraLog.warn("StudioVoicePreviewer", "Preview playback failed", ["failureCode": "studio_preview_playback_failed"])
            errorMessage = "Voqora couldn't play this voice preview."
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        Task { @MainActor in
            self.player = nil
            self.playingVoice = nil
        }
    }
}
