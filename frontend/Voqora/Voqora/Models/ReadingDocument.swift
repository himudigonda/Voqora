import Foundation

nonisolated struct ReadingWordTiming: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval

    static func sanitized(_ words: [ReadingWordTiming]) -> [ReadingWordTiming]? {
        let valid = words
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.start.isFinite && $0.end.isFinite }
            .map { ReadingWordTiming(text: $0.text, start: $0.start, end: max($0.start, $0.end)) }
            .sorted { $0.start < $1.start }
        return valid.isEmpty ? nil : valid
    }
}

nonisolated struct ReadingSentence: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let block: Int
    let isHeading: Bool
    let words: [ReadingWordTiming]?
}

nonisolated struct ReadingDocument: Equatable, Sendable {
    let sentences: [ReadingSentence]

    static let empty = ReadingDocument(sentences: [])

    func startsBlock(_ index: Int) -> Bool {
        guard sentences.indices.contains(index) else { return false }
        return index == 0 || sentences[index - 1].block != sentences[index].block
    }
}

nonisolated extension ReadingDocument {
    init(transcript: TranscriptDocument, wordTimings: [Int: [ReadingWordTiming]] = [:]) {
        sentences = transcript.lines.map { line in
            ReadingSentence(
                id: line.id,
                text: line.text,
                start: line.start,
                end: line.end,
                block: line.block,
                isHeading: line.isHeading,
                words: wordTimings[line.id].flatMap(ReadingWordTiming.sanitized)
            )
        }
    }
}

nonisolated enum ReadingHighlight: Equatable, Sendable {
    case inactive
    case sentence(Int)
    case word(sentence: Int, word: Int)

    func wordIndex(inSentence index: Int) -> Int? {
        guard case let .word(sentence, word) = self, sentence == index else { return nil }
        return word
    }
}

nonisolated enum ReadingHighlighter {
    static func wordIndex(in words: [ReadingWordTiming], at time: TimeInterval) -> Int? {
        guard let first = words.first, time >= first.start else { return nil }
        var low = 0
        var high = words.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if words[mid].start <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    static func highlight(in document: ReadingDocument, sentenceIndex: Int?, at time: TimeInterval, emphasizesWords: Bool) -> ReadingHighlight {
        guard let sentenceIndex, document.sentences.indices.contains(sentenceIndex) else { return .inactive }
        guard emphasizesWords,
              let words = document.sentences[sentenceIndex].words,
              let word = wordIndex(in: words, at: time)
        else { return .sentence(sentenceIndex) }
        return .word(sentence: sentenceIndex, word: word)
    }
}

nonisolated enum ReadingWordLocator {
    static func ranges(of words: [ReadingWordTiming], in text: String) -> [Range<String.Index>?] {
        var cursor = text.startIndex
        return words.map { word -> Range<String.Index>? in
            let needle = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty,
                  let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: cursor ..< text.endIndex)
            else { return nil }
            cursor = found.upperBound
            return found
        }
    }
}
