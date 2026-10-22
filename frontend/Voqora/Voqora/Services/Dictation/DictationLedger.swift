import Foundation

nonisolated struct DictationLedger: Equatable, Sendable {
    private(set) var committed = ""
    private(set) var volatile = ""
    private(set) var uncoveredTail = ""
    private(set) var committedSegments = 0

    var text: String {
        Self.joined(committed, pending)
    }

    var isEmpty: Bool {
        text.isEmpty
    }

    private var pending: String {
        volatile.isEmpty ? uncoveredTail : volatile
    }

    mutating func revise(_ hypothesis: String) {
        volatile = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        uncoveredTail = ""
    }

    mutating func commit(_ segment: String) {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        uncoveredTail = Self.uncovered(pending, by: trimmed)
        volatile = ""
        append(trimmed)
    }

    mutating func sealAfterRecognitionEnded() {
        let unfinalized = volatile
        volatile = ""
        uncoveredTail = ""
        append(unfinalized)
    }

    mutating func sealAfterInterruption() {
        let heard = pending
        volatile = ""
        uncoveredTail = ""
        append(heard)
    }

    private mutating func append(_ segment: String) {
        guard !segment.isEmpty else { return }
        committed = Self.joined(committed, segment)
        committedSegments += 1
    }

    static func uncovered(_ hypothesis: String, by segment: String) -> String {
        let hypothesisWords = hypothesis.split(whereSeparator: \.isWhitespace)
        let segmentWordCount = segment.split(whereSeparator: \.isWhitespace).count
        guard segmentWordCount > 0, hypothesisWords.count > segmentWordCount else { return "" }
        return hypothesisWords.dropFirst(segmentWordCount).joined(separator: " ")
    }

    static func joined(_ head: String, _ tail: String) -> String {
        guard let last = head.last else { return tail }
        guard let first = tail.first else { return head }
        return needsSpace(between: last, and: first) ? head + " " + tail : head + tail
    }

    private static let closingPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "]", "}", "%", "…", "。", "、", "，", "！", "？"]

    private static func needsSpace(between last: Character, and first: Character) -> Bool {
        if last.isWhitespace || first.isWhitespace || closingPunctuation.contains(first) {
            return false
        }
        return !(isUnspacedScript(last) && isUnspacedScript(first))
    }

    private static func isUnspacedScript(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000 ... 0x30FF, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF, 0xFF00 ... 0xFFEF, 0x0E00 ... 0x0E7F:
                true
            default:
                false
            }
        }
    }
}
