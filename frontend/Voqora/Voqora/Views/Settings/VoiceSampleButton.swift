import SwiftUI

struct VoiceSampleButton: View {
    @EnvironmentObject var vm: DashboardViewModel
    @ObservedObject var player: VoiceSamplePlayer
    let voice: String
    let speed: Double

    private var isPlayingThisVoice: Bool {
        player.playingVoice == voice
    }

    var body: some View {
        Button {
            if VoiceBlendRules.isBlendID(voice) || SpeechEngineID.isDownloadableEngineVoice(voice) {
                player.stop()
                Task { await SpeechSource.$current.withValue(.sample) { await vm.speak(text: DashboardViewModel.sampleSentence(forVoice: voice), voice: voice) } }
            } else if isPlayingThisVoice {
                player.stop()
            } else {
                player.play(voice: voice, speed: speed)
            }
        } label: {
            Label(
                isPlayingThisVoice ? "Stop" : "Hear Sample",
                systemImage: isPlayingThisVoice ? "stop.fill" : "play.fill"
            )
        }
        .buttonStyle(.voqoraTonal)
        .accessibilityLabel(isPlayingThisVoice ? "Stop sample" : "Hear sample")
    }
}
