import Foundation

nonisolated enum DictationInsertionMode: String, CaseIterable, Identifiable, Sendable {
    case paste
    case copy

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .paste: "Paste into App"
        case .copy: "Copy Only"
        }
    }

    var detail: String {
        switch self {
        case .paste: "Voqora pastes the transcript where your cursor is, then puts your clipboard back."
        case .copy: "Voqora copies the transcript so you can paste it yourself."
        }
    }
}

nonisolated struct DictationPreferences: Equatable, Sendable {
    static let localeKey = "dictationLocaleIdentifier"
    static let insertionModeKey = "dictationInsertionMode"
    static let silenceTimeoutKey = "dictationSilenceTimeout"
    static let allowsServerRecognitionKey = "dictationAllowsServerRecognition"

    static let defaultSilenceTimeout: TimeInterval = 2
    static let silenceTimeoutOptions: [TimeInterval] = [0, 1, 1.5, 2, 3, 5]
    static let silenceTimeoutRange: ClosedRange<TimeInterval> = 0.5 ... 10

    let localeIdentifier: String?
    let insertionMode: DictationInsertionMode
    let silenceTimeout: TimeInterval?
    let allowsServerRecognition: Bool

    init(defaults: UserDefaults) {
        let storedLocale = defaults.string(forKey: Self.localeKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        localeIdentifier = storedLocale.isEmpty ? nil : storedLocale
        insertionMode = defaults.string(forKey: Self.insertionModeKey).flatMap(DictationInsertionMode.init(rawValue:)) ?? .paste
        silenceTimeout = Self.validatedSilenceTimeout(defaults.object(forKey: Self.silenceTimeoutKey) as? Double)
        allowsServerRecognition = defaults.bool(forKey: Self.allowsServerRecognitionKey)
    }

    static func validatedSilenceTimeout(_ stored: Double?) -> TimeInterval? {
        guard let stored else { return defaultSilenceTimeout }
        guard stored.isFinite, stored > 0 else { return nil }
        return min(max(stored, silenceTimeoutRange.lowerBound), silenceTimeoutRange.upperBound)
    }

    static func silenceOption(closestTo value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultSilenceTimeout }
        return silenceTimeoutOptions.min { abs($0 - value) < abs($1 - value) } ?? defaultSilenceTimeout
    }

    static func silenceLabel(for seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "Off" }
        guard seconds != 1 else { return "After 1 second" }
        return "After \(seconds.formatted(.number.precision(.fractionLength(0 ... 1)))) seconds"
    }
}
