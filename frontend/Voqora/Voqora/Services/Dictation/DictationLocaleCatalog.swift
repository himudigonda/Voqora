import Foundation
import Speech

nonisolated struct DictationLocaleOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

nonisolated enum DictationLocaleSupport: Equatable, Sendable {
    case onDevice
    case serverOnly
    case unsupported

    func note(allowsServerRecognition: Bool) -> String {
        switch self {
        case .onDevice:
            "Recognition runs on this Mac. Your audio never leaves it."
        case .serverOnly where allowsServerRecognition:
            "This language isn't available on device, so Apple's servers transcribe it."
        case .serverOnly:
            "On-device recognition isn't available for this language. Pick another language, or allow server recognition below."
        case .unsupported:
            "Dictation isn't available for this language on this Mac."
        }
    }
}

nonisolated enum DictationLocaleCatalog {
    static func options(identifiers: some Sequence<String>, displayLocale: Locale) -> [DictationLocaleOption] {
        Set(identifiers)
            .map { DictationLocaleOption(id: $0, name: displayLocale.localizedString(forIdentifier: $0) ?? $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func validatedSelection(_ stored: String, among options: [DictationLocaleOption]) -> String {
        guard !stored.isEmpty, !options.contains(where: { $0.id == stored }) else { return stored }
        DictationTrace.event("locale.reset", ["stored": stored])
        return ""
    }

    static func supportedOptions() -> [DictationLocaleOption] {
        options(identifiers: SFSpeechRecognizer.supportedLocales().map(\.identifier), displayLocale: .current)
    }

    static func support(forLocaleIdentifier identifier: String?) -> DictationLocaleSupport {
        guard let recognizer = SpeechCallbacks.recognizer(forLocaleIdentifier: identifier) else { return .unsupported }
        return recognizer.supportsOnDeviceRecognition ? .onDevice : .serverOnly
    }
}
