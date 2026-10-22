import Foundation

nonisolated enum ProcessingTimeEstimate {
    static let mingRealTimeFactor = 3.2
    static let mingColdStartSeconds = 60.0
    static let mingNote = "Ming renders slower than real time."

    static func seconds(forVoice voice: String, audioSeconds: Double, baselineSeconds: Double) -> Double {
        switch SpeechEngineID.engine(forVoice: voice) {
        case SpeechEngineID.ming:
            max(0, audioSeconds) * mingRealTimeFactor + mingColdStartSeconds
        default:
            baselineSeconds
        }
    }

    static func note(forVoice voice: String) -> String? {
        SpeechEngineID.isMingVoice(voice) ? mingNote : nil
    }
}
