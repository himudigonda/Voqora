import Foundation

nonisolated enum DictationPhase: Equatable, Sendable {
    case idle
    case preparing
    case listening
    case finishing
    case inserting

    var isCapturing: Bool {
        self == .listening || self == .finishing
    }
}

nonisolated enum DictationEvent: Equatable, Sendable {
    case toggle
    case cancel
    case ready
    case transcriptChanged(String)
    case silenceDetected
    case recognitionEnded(String)
    case recognitionFailed
    case finishTimedOut
    case failed(DictationIssue)
    case insertionFinished
    case abandonInsertion
}

nonisolated enum DictationEffect: Equatable, Sendable {
    case nothing
    case prepare
    case finishListening
    case insert(String)
    case stop
    case report(DictationIssue)
}

nonisolated struct DictationStateMachine: Equatable, Sendable {
    private(set) var phase: DictationPhase = .idle
    private(set) var transcript = ""

    mutating func handle(_ event: DictationEvent) -> DictationEffect {
        switch event {
        case .toggle:
            toggle()
        case .cancel:
            cancel()
        case .ready:
            becomeReady()
        case let .transcriptChanged(text):
            update(text)
        case .silenceDetected:
            phase == .listening ? beginFinishing() : .nothing
        case let .recognitionEnded(text):
            end(with: text, ifEmpty: .nothingHeard)
        case .recognitionFailed:
            end(with: transcript, ifEmpty: phase == .finishing ? .nothingHeard : .recognitionFailed)
        case .finishTimedOut:
            phase == .finishing ? end(with: transcript, ifEmpty: .nothingHeard) : .nothing
        case let .failed(issue):
            fail(issue)
        case .insertionFinished:
            finishInsertion()
        case .abandonInsertion:
            abandonInsertion()
        }
    }

    private mutating func toggle() -> DictationEffect {
        switch phase {
        case .idle:
            phase = .preparing
            transcript = ""
            return .prepare
        case .preparing:
            return cancel()
        case .listening:
            return beginFinishing()
        case .finishing:
            return end(with: transcript, ifEmpty: .nothingHeard)
        case .inserting:
            return .nothing
        }
    }

    private mutating func cancel() -> DictationEffect {
        guard phase != .idle, phase != .inserting else { return .nothing }
        phase = .idle
        transcript = ""
        return .stop
    }

    private mutating func becomeReady() -> DictationEffect {
        guard phase == .preparing else {
            return phase == .idle ? .stop : .nothing
        }
        phase = .listening
        return .nothing
    }

    private mutating func update(_ text: String) -> DictationEffect {
        guard phase.isCapturing else { return .nothing }
        transcript = text
        return .nothing
    }

    private mutating func beginFinishing() -> DictationEffect {
        phase = .finishing
        return .finishListening
    }

    private mutating func end(with text: String, ifEmpty issue: DictationIssue) -> DictationEffect {
        guard phase.isCapturing else { return .nothing }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = cleaned
        guard !cleaned.isEmpty else {
            phase = .idle
            return .report(issue)
        }
        phase = .inserting
        return .insert(cleaned)
    }

    private mutating func fail(_ issue: DictationIssue) -> DictationEffect {
        guard phase != .idle, phase != .inserting else { return .nothing }
        phase = .idle
        transcript = ""
        return .report(issue)
    }

    private mutating func abandonInsertion() -> DictationEffect {
        guard phase == .inserting else { return .nothing }
        phase = .idle
        transcript = ""
        return .nothing
    }

    private mutating func finishInsertion() -> DictationEffect {
        guard phase == .inserting else { return .nothing }
        phase = .idle
        return .nothing
    }
}
