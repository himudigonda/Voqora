import Foundation
import NaturalLanguage

nonisolated struct TranscriptLine: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let page: Int
    let block: Int
    let isHeading: Bool
    let isNarrated: Bool
    let isExactlyTimed: Bool
}

nonisolated struct TranscriptDocument: Equatable, Sendable {
    let lines: [TranscriptLine]

    static let empty = TranscriptDocument(lines: [])

    var isEmpty: Bool {
        lines.isEmpty
    }

    func lineIndex(at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        var low = 0
        var high = lines.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].start <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    func progress(of index: Int, at time: TimeInterval) -> Double {
        guard lines.indices.contains(index) else { return 0 }
        let line = lines[index]
        guard line.end > line.start else { return time >= line.start ? 1 : 0 }
        return min(1, max(0, (time - line.start) / (line.end - line.start)))
    }
}

nonisolated extension TranscriptDocument {
    struct TimedLine: Codable, Equatable, Sendable {
        let paragraph: Int
        let text: String
        let start: Double
        let end: Double
    }

    init(transcript: AudiobookService.Transcript) {
        let pageStarts = transcript.pageToTime
            .compactMap { key, time in Int(key).map { (page: $0, time: time) } }
            .sorted { $0.time < $1.time }
        var builder = Builder()
        for (index, entry) in pageStarts.enumerated() {
            let key = String(entry.page)
            let end = index + 1 < pageStarts.count ? pageStarts[index + 1].time : transcript.totalAudioSeconds
            let narrated = !TranscriptText.silentPageStatuses.contains(transcript.pageStatus?[key] ?? "")
            if narrated, let timed = transcript.lines?[key], !timed.isEmpty {
                builder.appendTimed(timed, page: entry.page)
            } else if let text = transcript.pages[key] {
                builder.appendEstimated(
                    text: text,
                    page: entry.page,
                    start: entry.time,
                    end: max(entry.time, end),
                    narrated: narrated
                )
            }
        }
        self.init(lines: builder.lines)
    }

    init(spokenText: String, duration: TimeInterval) {
        var builder = Builder()
        builder.appendEstimated(text: spokenText, page: 0, start: 0, end: max(0, duration), narrated: true)
        self.init(lines: builder.lines)
    }

    private struct Piece {
        let text: String
        let block: Int
        let heading: Bool
    }

    private struct Builder {
        private(set) var lines: [TranscriptLine] = []
        private var block = -1

        mutating func appendTimed(_ timed: [TimedLine], page: Int) {
            var lastParagraph: Int?
            for line in timed {
                if line.paragraph != lastParagraph {
                    block += 1
                    lastParagraph = line.paragraph
                }
                let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                lines.append(
                    TranscriptLine(
                        id: lines.count,
                        text: text,
                        start: line.start,
                        end: max(line.start, line.end),
                        page: page,
                        block: block,
                        isHeading: TranscriptText.isHeadingLike(text) && isSoleLine(of: line, in: timed),
                        isNarrated: true,
                        isExactlyTimed: true
                    )
                )
            }
        }

        mutating func appendEstimated(text: String, page: Int, start: TimeInterval, end: TimeInterval, narrated: Bool) {
            var pieces: [Piece] = []
            for paragraph in TranscriptText.splitIntoParagraphs(text) where !TranscriptText.isBlankMarker(paragraph) {
                block += 1
                if TranscriptText.isHeadingLike(paragraph) {
                    pieces.append(Piece(text: paragraph, block: block, heading: true))
                    continue
                }
                for row in paragraph.components(separatedBy: "\n") {
                    let trimmed = row.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    for sentence in TranscriptText.splitIntoSentences(trimmed) {
                        pieces.append(Piece(text: sentence, block: block, heading: false))
                    }
                }
            }
            guard !pieces.isEmpty else { return }
            let weights = pieces.map { Double($0.text.count) + TranscriptText.pauseWeight }
            let total = weights.reduce(0, +)
            let span = max(0, end - start)
            var cursor = start
            for (piece, weight) in zip(pieces, weights) {
                let length = total > 0 ? span * weight / total : 0
                lines.append(
                    TranscriptLine(
                        id: lines.count,
                        text: piece.text,
                        start: cursor,
                        end: cursor + length,
                        page: page,
                        block: piece.block,
                        isHeading: piece.heading,
                        isNarrated: narrated,
                        isExactlyTimed: false
                    )
                )
                cursor += length
            }
        }

        private func isSoleLine(of line: TimedLine, in timed: [TimedLine]) -> Bool {
            timed.lazy.filter { $0.paragraph == line.paragraph }.prefix(2).count == 1
        }
    }
}

nonisolated enum TranscriptText {
    static let pauseWeight = 6.0
    static let silentPageStatuses: Set<String> = ["tts_failed", "duplicate"]

    private static let lineEnders: Set<Character> = [".", "!", "?", ":", ";", "\"", "'", ")", "]", "\u{201D}", "\u{2019}"]

    static func isBlankMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "-" || (trimmed.hasPrefix("[blank") && trimmed.hasSuffix("]"))
    }

    static func isHeadingLike(_ paragraph: String) -> Bool {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 70, !trimmed.contains("\n") else { return false }
        guard let last = trimmed.last, !".!?,;:".contains(last) else { return false }
        return trimmed.split(separator: " ").count <= 12
    }

    static func isChapterTitle(_ text: String) -> Bool {
        let visible = text.filter { !$0.isWhitespace }
        let letters = visible.filter(\.isLetter).count
        guard letters >= 3, let first = visible.first, first.isLetter || first.isNumber else { return false }
        return Double(letters) / Double(visible.count) >= 0.6
    }

    static func joinLines(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            guard let last = result.last else {
                result = line
                continue
            }
            result += lineEnders.contains(last) ? "\n" : " "
            result += line
        }
        return result
    }

    static func splitIntoParagraphs(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var paragraphs: [String] = []
        var current: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(joinLines(current))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            paragraphs.append(joinLines(current))
        }
        return paragraphs
    }

    static func splitIntoSentences(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex ..< text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }
        return sentences.isEmpty ? [text] : sentences
    }
}
