import AVFoundation
import Combine
import Foundation

@MainActor
final class VoiceSamplePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingVoice: String?

    private var player: AVAudioPlayer?

    var isPlaying: Bool {
        playingVoice != nil
    }

    func play(voice: String, speed: Double) {
        stop()
        guard let url = Bundle.main.url(forResource: voice, withExtension: "wav") else {
            VoqoraLog.warn("VoiceSamplePlayer", "No bundled sample", ["voice": voice])
            return
        }
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.enableRate = true
            newPlayer.rate = Float(min(2.0, max(0.5, speed)))
            newPlayer.prepareToPlay()
            newPlayer.play()
            player = newPlayer
            playingVoice = voice
        } catch {
            VoqoraLog.warn("VoiceSamplePlayer", "Sample playback failed", ["voice": voice])
            playingVoice = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingVoice = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        Task { @MainActor in
            self.player = nil
            self.playingVoice = nil
        }
    }
}
