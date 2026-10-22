import FluidAudio
import Foundation

nonisolated enum LocalSpeechModel: String, CaseIterable, Identifiable, Sendable {
    case parakeet
    case bark
    case barkClean

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .parakeet: "Parakeet"
        case .bark: "Bark"
        case .barkClean: "Bark Clean"
        }
    }

    var downloadDescription: String {
        switch self {
        case .parakeet: "about 470 MB"
        case .bark: "about 440 MB"
        case .barkClean: "about 450 MB"
        }
    }

    var manifest: [BarkModelFile]? {
        switch self {
        case .parakeet: nil
        case .bark: BarkModelManifest.bark
        case .barkClean: BarkModelManifest.barkClean
        }
    }

    var repositoryFolder: String? {
        switch self {
        case .parakeet: nil
        case .bark: "bark-3.0"
        case .barkClean: "bark-3.0-clean"
        }
    }

    var loadVersion: AsrModelVersion {
        self == .parakeet ? .v3 : .ultra
    }

    var defaultDirectory: URL {
        guard let repositoryFolder else { return AsrModels.defaultCacheDirectory(for: .v3) }
        return AsrModels.defaultCacheDirectory(for: .v3)
            .deletingLastPathComponent()
            .appendingPathComponent("bark-3.0-coreml", isDirectory: true)
            .appendingPathComponent(repositoryFolder, isDirectory: true)
    }
}
