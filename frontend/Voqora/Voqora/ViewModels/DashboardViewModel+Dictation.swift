import Foundation

extension DashboardViewModel: DictationSpeechPausing {
    func pauseSpeechForDictation() {
        if status == .thinking || audiobookVM?.isPreparingPlayback == true {
            VoqoraLog.info("DashboardViewModel", "Stopping pending speech for dictation")
            stopPlayback()
        } else if audio.isPlaying {
            VoqoraLog.info("DashboardViewModel", "Pausing speech for dictation")
            togglePlayback()
        }
    }
}
