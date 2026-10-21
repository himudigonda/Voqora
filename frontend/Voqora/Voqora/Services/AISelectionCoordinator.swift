import AppKit
import Foundation

@MainActor
final class AISelectionCoordinator {
    enum Action: String, Equatable {
        case summarize
        case translate
    }

    enum Message {
        static let noSelection = "Select text in any app, then try again."
        static let needsAccessibility = "Voqora needs Accessibility access to read your selection. Opening System Settings…"
        static let needsProvider = "Connect an AI provider in Settings > AI to summarize or translate selections."
        static let engineStarting = "Voqora is still starting. Try again in a moment."
        static let selectionTooLong = "That selection is too long to summarize. Select a shorter passage."
        static let translationTooLong = "That selection is too long to translate. Select up to 20,000 characters."
    }

    struct Dependencies {
        let readSelection: @MainActor () async -> String?
        let isAccessibilityTrusted: @MainActor () -> Bool
        let openAccessibilitySettings: @MainActor () -> Void
        let openAIPreferences: @MainActor () -> Void
        let announce: @MainActor (String) -> Void
        let translateTarget: @MainActor () -> AILanguage

        static func live(openAIPreferences: @escaping @MainActor () -> Void) -> Dependencies {
            Dependencies(
                readSelection: { await SelectionManager.getSelectedText() },
                isAccessibilityTrusted: { AXIsProcessTrusted() },
                openAccessibilitySettings: {
                    NSApp.activate(ignoringOtherApps: true)
                    PermissionsService.shared.openAccessibilitySettings()
                },
                openAIPreferences: openAIPreferences,
                announce: { body in
                    PermissionsService.shared.scheduleNotification(title: "Voqora is working", body: body)
                },
                translateTarget: {
                    AIReadingPreferences.translateTarget(defaults: .standard, preferredLanguages: Locale.preferredLanguages)
                }
            )
        }
    }

    private let speaker: any SpeechInputSpeaking
    private let client: any AIReadingServing
    private let credential: AICredentialSource
    private let dependencies: Dependencies
    private let runner = AIRequestRunner()
    private(set) var activeAction: Action?

    init(
        speaker: any SpeechInputSpeaking,
        credential: @escaping AICredentialSource,
        dependencies: Dependencies,
        client: (any AIReadingServing)? = nil
    ) {
        self.speaker = speaker
        self.credential = credential
        self.dependencies = dependencies
        self.client = client ?? AIReadingClient()
    }

    func summarizeSelection() async {
        await perform(.summarize)
    }

    func translateSelection() async {
        await perform(.translate)
    }

    func cancel() {
        runner.cancel()
        activeAction = nil
    }

    private func perform(_ action: Action) async {
        cancel()
        guard let credential = credential() else {
            speaker.showTransientError(Message.needsProvider)
            dependencies.openAIPreferences()
            return
        }
        guard speaker.isBackendOnline else {
            speaker.showTransientError(Message.engineStarting)
            return
        }
        guard let text = await dependencies.readSelection()?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            if dependencies.isAccessibilityTrusted() {
                speaker.showTransientError(Message.noSelection)
            } else {
                speaker.showTransientError(Message.needsAccessibility)
                dependencies.openAccessibilitySettings()
            }
            return
        }
        switch action {
        case .summarize:
            guard AIReadingLimits.length(of: text) <= AIReadingLimits.sourceCharacters else {
                speaker.showTransientError(Message.selectionTooLong)
                return
            }
            start(.summarize, announcement: "Summarizing your selection.") { [client] in
                let summary = try await client.summarize(.text(text), length: .short, language: nil, credential: credential)
                return (summary.summary, nil)
            }
        case .translate:
            guard AIReadingLimits.length(of: text) <= AIReadingLimits.translateCharacters else {
                speaker.showTransientError(Message.translationTooLong)
                return
            }
            let target = dependencies.translateTarget()
            start(.translate, announcement: "Translating your selection into \(target.displayName).") { [client] in
                let translation = try await client.translate(text, to: target, credential: credential)
                return (translation.text, target)
            }
        }
    }

    private func start(
        _ action: Action,
        announcement: String,
        operation: @escaping @MainActor () async throws -> (String, AILanguage?)
    ) {
        VoqoraLog.info("AISelectionCoordinator", "AI selection shortcut started", ["action": action.rawValue])
        activeAction = action
        dependencies.announce(announcement)
        runner.run { [weak self] () async throws in
            let (output, language) = try await operation()
            try Task.checkCancellation()
            await self?.speak(output, language: language)
        } completion: { [weak self] result in
            guard let self else { return }
            activeAction = nil
            guard case let .failure(error) = result else { return }
            VoqoraLog.warn("AISelectionCoordinator", "AI selection shortcut failed", ["action": action.rawValue, "failureCode": error.code ?? "ai_failed"])
            speaker.showTransientError(error.message)
            if error.kind == .providerRequired || error.kind == .providerSettings {
                dependencies.openAIPreferences()
            }
        }
    }

    private func speak(_ output: String, language: AILanguage?) async {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            speaker.showTransientError(AIReadingError.invalidResponse.message)
            return
        }
        let voice = language.map { AIVoiceMatcher.voice(for: $0, current: speaker.selectedVoice) }
            ?? LanguageDetector.voiceForText(trimmed, fallback: speaker.selectedVoice)
        await speaker.speakAIResult(text: trimmed, voice: voice)
    }
}
