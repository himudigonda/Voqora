import Foundation

nonisolated enum MingEmotion: String, CaseIterable, Sendable {
    case neutral
    case happy
    case sad
    case angry
    case fearful
    case disgusted
    case surprised

    var label: String {
        rawValue.capitalized
    }
}

nonisolated enum MingPace: String, CaseIterable, Sendable {
    case slow
    case normal
    case fast

    var label: String {
        rawValue.capitalized
    }
}

nonisolated enum MingPitch: String, CaseIterable, Sendable {
    case low
    case normal
    case high

    var label: String {
        rawValue.capitalized
    }
}

nonisolated enum MingDialect: String, CaseIterable, Sendable {
    case cantonese
    case sichuanese

    var label: String {
        rawValue.capitalized
    }
}

nonisolated enum MingStylePreset: String, CaseIterable, Identifiable, Sendable {
    case warmStoryteller = "Warm storyteller"
    case calmNarrator = "Calm narrator"
    case excitedPresenter = "Excited presenter"
    case whisper = "Whisper"
    case newsAnchor = "News anchor"

    var id: String {
        rawValue
    }
}

nonisolated enum MingParalinguisticTags {
    static let all = [
        "[Laughter]", "[Sigh]", "[Breathing]", "[Cough]", "[Uhm]",
        "[Surprise-ah]", "[Surprise-oh]",
        "[Question-ah]", "[Question-ei]", "[Question-en]", "[Question-oh]", "[Question-huh]",
        "[Confirmation-en]", "[Dissatisfaction-hnn]",
    ]

    static let hint = "Add these to your text for natural sounds: " + all.joined(separator: " ")
}

nonisolated struct SpeechDelivery: Equatable, Encodable, Sendable {
    static let maxStyleLength = 300

    var emotion: MingEmotion?
    var style: String?
    var pace: MingPace?
    var pitch: MingPitch?
    var dialect: MingDialect?

    init(
        emotion: MingEmotion? = nil,
        style: String? = nil,
        pace: MingPace? = nil,
        pitch: MingPitch? = nil,
        dialect: MingDialect? = nil
    ) {
        self.emotion = emotion
        self.style = Self.normalizedStyle(style)
        self.pace = pace == .normal ? nil : pace
        self.pitch = pitch == .normal ? nil : pitch
        self.dialect = dialect
    }

    init(emotionRaw: String, style: String, paceRaw: String, pitchRaw: String, dialectRaw: String) {
        self.init(
            emotion: MingEmotion(rawValue: emotionRaw),
            style: style,
            pace: MingPace(rawValue: paceRaw),
            pitch: MingPitch(rawValue: pitchRaw),
            dialect: MingDialect(rawValue: dialectRaw)
        )
    }

    var isEmpty: Bool {
        emotion == nil && style == nil && pace == nil && pitch == nil && dialect == nil
    }

    var payload: [String: String] {
        var fields: [String: String] = [:]
        fields["emotion"] = emotion?.rawValue
        fields["style"] = style
        fields["pace"] = pace?.rawValue
        fields["pitch"] = pitch?.rawValue
        fields["dialect"] = dialect?.rawValue
        return fields
    }

    func tailored(forVoice voiceID: String, known voice: SpeechEngineVoice?) -> SpeechDelivery? {
        guard SpeechEngineID.isMingVoice(voiceID) else { return nil }
        var adjusted = self
        if let voice, !voice.isChinese {
            adjusted.dialect = nil
        }
        return adjusted.isEmpty ? nil : adjusted
    }

    @MainActor
    static func stored(
        forVoice voiceID: String,
        defaults: UserDefaults = .standard,
        engines: SpeechEngineStore? = nil
    ) -> SpeechDelivery? {
        guard SpeechEngineID.isMingVoice(voiceID) else { return nil }
        return SpeechDelivery(
            emotionRaw: defaults.string(forKey: "mingEmotion") ?? "",
            style: defaults.string(forKey: "mingStyle") ?? "",
            paceRaw: defaults.string(forKey: "mingPace") ?? "",
            pitchRaw: defaults.string(forKey: "mingPitch") ?? "",
            dialectRaw: defaults.string(forKey: "mingDialect") ?? ""
        ).tailored(forVoice: voiceID, known: (engines ?? SpeechEngineStore.shared).voice(id: voiceID))
    }

    static func deliverable(_ delivery: SpeechDelivery?, forVoice voice: String?) -> SpeechDelivery? {
        guard let delivery, !delivery.isEmpty, let voice, SpeechEngineID.isMingVoice(voice) else { return nil }
        return delivery
    }

    var formValue: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func cappedStyle(_ text: String) -> String {
        limited(scrubbed(text))
    }

    static func normalizedStyle(_ style: String?) -> String? {
        guard let style else { return nil }
        let result = trimmedWhitespace(limited(trimmedWhitespace(scrubbed(style))))
        return result.isEmpty ? nil : result
    }

    private static func limited(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(maxStyleLength)))
    }

    private static func scrubbed(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format: continue
            default: kept.append(scalar)
            }
        }
        return String(kept)
    }

    private static func trimmedWhitespace(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum CodingKeys: String, CodingKey {
        case emotion
        case style
        case pace
        case pitch
        case dialect
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(emotion?.rawValue, forKey: .emotion)
        try container.encodeIfPresent(style, forKey: .style)
        try container.encodeIfPresent(pace?.rawValue, forKey: .pace)
        try container.encodeIfPresent(pitch?.rawValue, forKey: .pitch)
        try container.encodeIfPresent(dialect?.rawValue, forKey: .dialect)
    }
}
