import Foundation

nonisolated enum PodcastScriptIssue: Hashable, Sendable {
    case missingTitle
    case titleTooLong
    case tooFewSpeakers
    case tooManySpeakers
    case invalidSpeakerID(speaker: Int)
    case duplicateSpeakerID(speaker: Int)
    case missingSpeakerName(speaker: Int)
    case speakerNameTooLong(speaker: Int)
    case missingVoice(speaker: Int)
    case tooFewTurns
    case tooManyTurns
    case emptyTurn(turn: Int)
    case turnTooLong(turn: Int, length: Int)
    case unknownSpeaker(turn: Int)
    case invalidPause(turn: Int)
    case sectionTooLong(turn: Int)

    var turnIndex: Int? {
        switch self {
        case let .emptyTurn(turn), let .turnTooLong(turn, _), let .unknownSpeaker(turn),
             let .invalidPause(turn), let .sectionTooLong(turn):
            turn
        default:
            nil
        }
    }

    var speakerIndex: Int? {
        switch self {
        case let .invalidSpeakerID(speaker), let .duplicateSpeakerID(speaker), let .missingSpeakerName(speaker),
             let .speakerNameTooLong(speaker), let .missingVoice(speaker):
            speaker
        default:
            nil
        }
    }

    var message: String {
        switch self {
        case .missingTitle:
            "Give the script a title."
        case .titleTooLong:
            "Keep the title to \(PodcastLimits.titleCharacters) characters or fewer."
        case .tooFewSpeakers:
            "Add at least one speaker."
        case .tooManySpeakers:
            "A script can have up to \(PodcastLimits.speakers.upperBound) speakers."
        case let .invalidSpeakerID(speaker):
            "Speaker \(speaker + 1) has an id Voqora can't use. Remove it and add a new speaker."
        case let .duplicateSpeakerID(speaker):
            "Speaker \(speaker + 1) repeats another speaker's id. Remove it and add a new speaker."
        case let .missingSpeakerName(speaker):
            "Speaker \(speaker + 1) needs a name."
        case let .speakerNameTooLong(speaker):
            "Keep speaker \(speaker + 1)'s name to \(PodcastLimits.speakerNameCharacters) characters or fewer."
        case let .missingVoice(speaker):
            "Choose a voice for speaker \(speaker + 1)."
        case .tooFewTurns:
            "Add at least one turn."
        case .tooManyTurns:
            "A script can have up to \(PodcastLimits.turns.upperBound) turns."
        case let .emptyTurn(turn):
            "Turn \(turn + 1) has no text."
        case let .turnTooLong(turn, length):
            "Turn \(turn + 1) has \(length) characters. Keep each turn to \(PodcastLimits.turnCharacters) or fewer."
        case let .unknownSpeaker(turn):
            "Choose a speaker for turn \(turn + 1)."
        case let .invalidPause(turn):
            "Turn \(turn + 1)'s pause must be between 0 and \(Int(PodcastLimits.pauseSeconds.upperBound)) seconds."
        case let .sectionTooLong(turn):
            "Keep turn \(turn + 1)'s chapter title to \(PodcastLimits.sectionCharacters) characters or fewer."
        }
    }
}

nonisolated enum PodcastScriptValidator {
    static func issues(in script: PodcastScript) -> [PodcastScriptIssue] {
        titleIssues(script.title) + speakerIssues(script.speakers) + turnIssues(script.turns, speakers: script.speakers)
    }

    static func issuesByTurn(_ issues: [PodcastScriptIssue]) -> [Int: [PodcastScriptIssue]] {
        var grouped: [Int: [PodcastScriptIssue]] = [:]
        for issue in issues {
            if let turn = issue.turnIndex {
                grouped[turn, default: []].append(issue)
            }
        }
        return grouped
    }

    static func isSpeakerIDValid(_ id: String) -> Bool {
        id.range(of: PodcastLimits.speakerIDPattern, options: .regularExpression) != nil
    }

    private static func titleIssues(_ title: String) -> [PodcastScriptIssue] {
        let normalized = PodcastText.singleLine(title)
        if normalized.isEmpty {
            return [.missingTitle]
        }
        return PodcastLimits.length(of: normalized) > PodcastLimits.titleCharacters ? [.titleTooLong] : []
    }

    private static func speakerIssues(_ speakers: [PodcastSpeaker]) -> [PodcastScriptIssue] {
        var issues: [PodcastScriptIssue] = []
        if speakers.count < PodcastLimits.speakers.lowerBound {
            issues.append(.tooFewSpeakers)
        } else if speakers.count > PodcastLimits.speakers.upperBound {
            issues.append(.tooManySpeakers)
        }
        var seenIDs: Set<String> = []
        for (index, speaker) in speakers.enumerated() {
            if !isSpeakerIDValid(speaker.id) {
                issues.append(.invalidSpeakerID(speaker: index))
            } else if !seenIDs.insert(speaker.id).inserted {
                issues.append(.duplicateSpeakerID(speaker: index))
            }
            let name = PodcastText.singleLine(speaker.name)
            if name.isEmpty {
                issues.append(.missingSpeakerName(speaker: index))
            } else if PodcastLimits.length(of: name) > PodcastLimits.speakerNameCharacters {
                issues.append(.speakerNameTooLong(speaker: index))
            }
            if speaker.voice.isEmpty {
                issues.append(.missingVoice(speaker: index))
            }
        }
        return issues
    }

    private static func turnIssues(_ turns: [PodcastTurn], speakers: [PodcastSpeaker]) -> [PodcastScriptIssue] {
        var issues: [PodcastScriptIssue] = []
        if turns.count < PodcastLimits.turns.lowerBound {
            issues.append(.tooFewTurns)
        } else if turns.count > PodcastLimits.turns.upperBound {
            issues.append(.tooManyTurns)
        }
        let speakerIDs = Set(speakers.map(\.id))
        for (index, turn) in turns.enumerated() {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let length = PodcastLimits.length(of: text)
            if text.isEmpty || text == "-" {
                issues.append(.emptyTurn(turn: index))
            } else if length > PodcastLimits.turnCharacters {
                issues.append(.turnTooLong(turn: index, length: length))
            }
            if !speakerIDs.contains(turn.speakerID) {
                issues.append(.unknownSpeaker(turn: index))
            }
            if !turn.pauseAfterSeconds.isFinite || !PodcastLimits.pauseSeconds.contains(turn.pauseAfterSeconds) {
                issues.append(.invalidPause(turn: index))
            }
            if let section = turn.section, PodcastLimits.length(of: PodcastText.singleLine(section)) > PodcastLimits.sectionCharacters {
                issues.append(.sectionTooLong(turn: index))
            }
        }
        return issues
    }
}
