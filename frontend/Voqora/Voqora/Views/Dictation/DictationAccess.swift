import Foundation

nonisolated struct DictationAccessGap: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let pane: PrivacySettingsPane
}

nonisolated enum DictationAccessGaps {
    static func make(
        microphone: DictationPermissionStatus,
        speechRecognition: DictationPermissionStatus,
        accessibilityGranted: Bool
    ) -> [DictationAccessGap] {
        var gaps: [DictationAccessGap] = []
        if microphone == .denied {
            gaps.append(DictationAccessGap(
                id: "microphone",
                title: "Microphone is off",
                detail: "Voqora needs it to hear you.",
                pane: .microphone
            ))
        }
        if speechRecognition == .denied {
            gaps.append(DictationAccessGap(
                id: "speech",
                title: "Speech Recognition is off",
                detail: "Voqora needs it to turn your voice into text.",
                pane: .speechRecognition
            ))
        }
        if !accessibilityGranted {
            gaps.append(DictationAccessGap(
                id: "accessibility",
                title: "Accessibility is off",
                detail: "Without it Voqora can only copy what you say, not paste it for you.",
                pane: .accessibility
            ))
        }
        return gaps
    }
}

nonisolated enum DictationStateLabel {
    static func title(for phase: DictationPhase, isTidying: Bool) -> String {
        switch phase {
        case .idle: "Ready"
        case .preparing: "Getting ready…"
        case .listening: "Listening"
        case .finishing: "Finishing…"
        case .inserting: isTidying ? "Tidying…" : "Inserting…"
        }
    }

    static func placeholder(for phase: DictationPhase, shortcut: String, isWarmingUp: Bool = false) -> String {
        if phase == .preparing {
            return "Loading speech recognition. Start speaking when this says Listening."
        }
        if isWarmingUp, phase == .listening {
            return "Keep talking. The speech model is still loading, so your words will appear in a moment."
        }
        if isWarmingUp, phase == .finishing {
            return "Got it. Your words will appear as soon as the speech model finishes loading."
        }
        return "Start speaking. Press \(shortcut) when you're done."
    }

    static func keycaps(from shortcut: String?) -> [String] {
        guard let shortcut, !shortcut.isEmpty else { return [] }
        let modifierGlyphs: Set<Character> = ["⌃", "^", "⌥", "⇧", "⌘"]
        let modifiers = shortcut.prefix { modifierGlyphs.contains($0) }
        let keyName = String(shortcut.dropFirst(modifiers.count))
        var caps = modifiers.map { $0 == "^" ? "⌃" : String($0) }
        if !keyName.isEmpty {
            caps.append(keyName)
        }
        return caps
    }
}
