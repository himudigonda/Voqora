import AppIntents
import Foundation

nonisolated struct VoqoraIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: message)
    }
}

nonisolated extension SpeechInputOutcome {
    func requireSuccess() throws {
        if case let .failed(message) = self {
            throw VoqoraIntentError(message: message)
        }
    }
}

extension SpeechInputCoordinator {
    static func requireActive() throws -> SpeechInputCoordinator {
        guard let coordinator = active else {
            throw VoqoraIntentError(message: Message.notRunning)
        }
        return coordinator
    }
}

nonisolated struct VoqoraVoiceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Voice"
    static let defaultQuery = VoqoraVoiceQuery()
    static let all: [VoqoraVoiceEntity] = DashboardViewModel.voiceCatalog.map {
        VoqoraVoiceEntity(id: $0.id, name: $0.name, language: $0.language)
    }

    let id: String
    let name: String
    let language: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(language)")
    }
}

nonisolated struct VoqoraVoiceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [VoqoraVoiceEntity] {
        VoqoraVoiceEntity.all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [VoqoraVoiceEntity] {
        VoqoraVoiceEntity.all
    }
}

nonisolated struct SpeakTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Speak Text"

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Voice")
    var voice: VoqoraVoiceEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        let inputs = try SpeechInputCoordinator.requireActive()
        try await inputs.speak(text, voice: voice?.id).requireSuccess()
        return .result()
    }
}

nonisolated struct SpeakClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Speak Clipboard"

    @MainActor
    func perform() async throws -> some IntentResult {
        let inputs = try SpeechInputCoordinator.requireActive()
        try await inputs.speakClipboard().requireSuccess()
        return .result()
    }
}

nonisolated struct TogglePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause or Resume Speech"

    @MainActor
    func perform() async throws -> some IntentResult {
        try SpeechInputCoordinator.requireActive().togglePlayback()
        return .result()
    }
}

nonisolated struct StopSpeechIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Speech"

    @MainActor
    func perform() async throws -> some IntentResult {
        try SpeechInputCoordinator.requireActive().stopPlayback()
        return .result()
    }
}

nonisolated struct VoqoraAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SpeakTextIntent(),
            phrases: ["Speak text with \(.applicationName)"],
            shortTitle: "Speak Text",
            systemImageName: "text.bubble"
        )
        AppShortcut(
            intent: SpeakClipboardIntent(),
            phrases: ["Speak clipboard with \(.applicationName)", "Read my clipboard with \(.applicationName)"],
            shortTitle: "Speak Clipboard",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: TogglePlaybackIntent(),
            phrases: ["Pause or resume \(.applicationName)"],
            shortTitle: "Pause or Resume",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: StopSpeechIntent(),
            phrases: ["Stop \(.applicationName)"],
            shortTitle: "Stop Speech",
            systemImageName: "stop.fill"
        )
    }
}
