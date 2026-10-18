import Foundation

nonisolated enum AICitationLocator {
    static func line(for citation: AICitation, in document: TranscriptDocument) -> TranscriptLine? {
        let candidates = document.lines.filter { $0.page == citation.page && $0.isNarrated }
        guard !candidates.isEmpty else { return nil }
        let quote = normalized(citation.quote)
        guard !quote.isEmpty else { return candidates.first }

        let probe = String(quote.prefix(48))
        if let match = candidates.first(where: { line in
            let text = normalized(line.text)
            return !text.isEmpty && (text.contains(probe) || quote.contains(text))
        }) {
            return match
        }

        let quoteWords = Set(quote.split(separator: " "))
        let scored = candidates.map { line -> (line: TranscriptLine, score: Int) in
            let words = Set(normalized(line.text).split(separator: " "))
            return (line, words.intersection(quoteWords).count)
        }
        let best = scored.max { $0.score < $1.score }
        if let best, best.score > 0 {
            return best.line
        }
        return candidates.first
    }

    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }
}
