import CoreGraphics
import Foundation

nonisolated struct OCRLine: Equatable, Sendable {
    let text: String
    let bounds: CGRect
}

nonisolated enum OCRTextAssembler {
    static let paragraphGapRatio: CGFloat = 0.8
    static let columnJumpRatio: CGFloat = 1.5
    static let shortLineRatio: CGFloat = 0.7

    private static let softHyphen: Character = "\u{00AD}"
    private static let lineBreakHyphens: Set<Character> = ["-", softHyphen, "\u{2010}"]
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", ":", "\u{3002}", "\u{FF01}", "\u{FF1F}"]
    private static let cjkRanges: [ClosedRange<UInt32>] = [
        0x3000 ... 0x303F,
        0x3040 ... 0x30FF,
        0x3400 ... 0x4DBF,
        0x4E00 ... 0x9FFF,
        0xF900 ... 0xFAFF,
        0xFF00 ... 0xFFEF,
    ]

    static func assemble(_ lines: [OCRLine]) -> String {
        var paragraphs: [String] = []
        var paragraph = ""
        var previous: OCRLine?
        for line in lines {
            let text = normalizedWhitespace(line.text)
            guard !text.isEmpty else { continue }
            let current = OCRLine(text: text, bounds: line.bounds)
            if let previous, startsParagraph(after: previous, next: current) {
                paragraphs.append(paragraph)
                paragraph = text
            } else {
                paragraph = paragraph.isEmpty ? text : join(paragraph, text)
            }
            previous = current
        }
        if !paragraph.isEmpty {
            paragraphs.append(paragraph)
        }
        return paragraphs.joined(separator: "\n\n")
    }

    static func startsParagraph(after previous: OCRLine, next: OCRLine) -> Bool {
        let lineHeight = max(previous.bounds.height, next.bounds.height)
        guard lineHeight > 0 else { return false }
        let gap = previous.bounds.minY - next.bounds.maxY
        if gap > lineHeight * paragraphGapRatio || gap < -lineHeight * columnJumpRatio {
            return true
        }
        return endsSentence(previous.text) && previous.bounds.width < next.bounds.width * shortLineRatio
    }

    static func join(_ head: String, _ tail: String) -> String {
        guard let last = head.last, let first = tail.first else { return head + tail }
        if endsWithLineBreakHyphen(head) {
            return first.isLowercase || last == softHyphen ? String(head.dropLast()) + tail : head + tail
        }
        if isCJK(last), isCJK(first) {
            return head + tail
        }
        return head + " " + tail
    }

    static func endsWithLineBreakHyphen(_ text: String) -> Bool {
        guard let last = text.last, lineBreakHyphens.contains(last) else { return false }
        return text.dropLast().last?.isLetter == true
    }

    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            cjkRanges.contains { $0.contains(scalar.value) }
        }
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return sentenceTerminators.contains(last)
    }

    private static func normalizedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
