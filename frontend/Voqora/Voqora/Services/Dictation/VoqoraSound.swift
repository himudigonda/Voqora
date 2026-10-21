import AppKit
import Foundation

nonisolated enum VoqoraSound: String, CaseIterable, Sendable {
    case dictationStart
    case dictationStop
    case dictationInserted
    case dictationError
    case speechStart
    case audiobookReady

    var fileName: String {
        switch self {
        case .dictationStart: "dictation-start"
        case .dictationStop: "dictation-stop"
        case .dictationInserted: "dictation-inserted"
        case .dictationError: "dictation-error"
        case .speechStart: "speech-start"
        case .audiobookReady: "audiobook-ready"
        }
    }

    static let fileExtension = "m4a"
}

@MainActor
protocol SoundPlaying: AnyObject {
    func play(_ sound: VoqoraSound)
}

@MainActor
final class SilentSoundPlayer: SoundPlaying {
    func play(_: VoqoraSound) {}
}

@MainActor
final class SoundPlayer: SoundPlaying {
    static let volume: Float = 0.35

    static let shared = SoundPlayer.makeShared()

    private static func makeShared() -> SoundPlayer {
        let loader: (VoqoraSound) -> NSSound? = RuntimeEnvironment.isRunningTests ? { _ in nil } : { bundleLoader($0) }
        return SoundPlayer(loader: loader, isEnabled: { DictationPreferences.playsSounds(in: .standard) })
    }

    private let isEnabled: () -> Bool
    private var sounds: [VoqoraSound: NSSound] = [:]

    init(loader: (VoqoraSound) -> NSSound?, isEnabled: @escaping () -> Bool) {
        self.isEnabled = isEnabled
        for sound in VoqoraSound.allCases {
            guard let loaded = loader(sound) else { continue }
            loaded.volume = Self.volume
            sounds[sound] = loaded
        }
    }

    static func bundleLoader(_ sound: VoqoraSound, bundle: Bundle = .main) -> NSSound? {
        guard let url = bundle.url(forResource: sound.fileName, withExtension: VoqoraSound.fileExtension, subdirectory: "Sounds")
            ?? bundle.url(forResource: sound.fileName, withExtension: VoqoraSound.fileExtension)
        else { return nil }
        return NSSound(contentsOf: url, byReference: false)
    }

    func play(_ sound: VoqoraSound) {
        guard isEnabled(), let loaded = sounds[sound] else { return }
        loaded.stop()
        loaded.play()
    }
}
