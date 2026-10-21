import Foundation

struct TranscriptScore: Equatable {
    let referenceWords: Int
    let hypothesisWords: Int
    let substitutions: Int
    let deletions: Int
    let insertions: Int
    let sentences: Int
    let droppedSentences: Int
    let repeatedInsertions: Int

    var wordErrorRate: Double {
        referenceWords == 0 ? 0 : Double(substitutions + deletions + insertions) / Double(referenceWords)
    }
}

enum TranscriptScoring {
    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                               "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    static func spelled(_ number: Int) -> String {
        if number < 20 {
            return ones[number]
        }
        if number < 100 {
            return tens[number / 10] + (number % 10 == 0 ? "" : " " + ones[number % 10])
        }
        if number < 1000 {
            return ones[number / 100] + " hundred" + (number % 100 == 0 ? "" : " " + spelled(number % 100))
        }
        return String(number)
    }

    static func words(_ text: String) -> [String] {
        var expanded = text.lowercased()
            .replacingOccurrences(of: "%", with: " percent")
            .replacingOccurrences(of: "-", with: " ")
        while let range = expanded.range(of: "[0-9]+", options: .regularExpression) {
            expanded.replaceSubrange(range, with: " " + spelled(Int(expanded[range]) ?? 0) + " ")
        }
        return expanded.split { !$0.isLetter && $0 != "'" }.map(String.init)
    }

    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".?!".contains(character) {
                result.append(current)
                current = ""
            }
        }
        result.append(current)
        return result.filter { !words($0).isEmpty }
    }

    static func score(reference: String, hypothesis: String) -> TranscriptScore {
        let ref = words(reference)
        let hyp = words(hypothesis)
        var cost = [[Int]](repeating: [Int](repeating: 0, count: hyp.count + 1), count: ref.count + 1)
        for row in 0 ... ref.count {
            cost[row][0] = row
        }
        for column in 0 ... hyp.count {
            cost[0][column] = column
        }
        if !ref.isEmpty, !hyp.isEmpty {
            for row in 1 ... ref.count {
                for column in 1 ... hyp.count {
                    let substitution = cost[row - 1][column - 1] + (ref[row - 1] == hyp[column - 1] ? 0 : 1)
                    cost[row][column] = min(cost[row - 1][column] + 1, cost[row][column - 1] + 1, substitution)
                }
            }
        }
        var matched = [Bool](repeating: false, count: ref.count)
        var row = ref.count
        var column = hyp.count
        var substitutions = 0
        var deletions = 0
        var inserted: [Int] = []
        while row > 0 || column > 0 {
            if row > 0, column > 0, cost[row][column] == cost[row - 1][column - 1] + (ref[row - 1] == hyp[column - 1] ? 0 : 1) {
                if ref[row - 1] == hyp[column - 1] {
                    matched[row - 1] = true
                } else {
                    substitutions += 1
                }
                row -= 1
                column -= 1
            } else if row > 0, cost[row][column] == cost[row - 1][column] + 1 {
                deletions += 1
                row -= 1
            } else {
                inserted.append(column - 1)
                column -= 1
            }
        }
        var offset = 0
        var dropped = 0
        let referenceSentences = sentences(reference)
        for sentence in referenceSentences {
            let count = words(sentence).count
            let hits = matched[offset ..< min(offset + count, matched.count)].filter(\.self).count
            if hits * 2 < count {
                dropped += 1
            }
            offset += count
        }
        let repeated = inserted.filter { index in
            hyp[max(0, index - 6) ..< index].contains(hyp[index])
        }.count
        return TranscriptScore(
            referenceWords: ref.count,
            hypothesisWords: hyp.count,
            substitutions: substitutions,
            deletions: deletions,
            insertions: inserted.count,
            sentences: referenceSentences.count,
            droppedSentences: dropped,
            repeatedInsertions: repeated
        )
    }
}

struct RecordedRecognitionEvent: Decodable {
    let final: Bool
    let text: String
}

enum DictationFixtures {
    static func url(_ name: String, _ ext: String) throws -> URL {
        let bundle = Bundle(for: FixtureAnchor.self)
        if let url = bundle.url(forResource: name, withExtension: ext) ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/Dictation") {
            return url
        }
        throw CocoaError(.fileNoSuchFile)
    }

    static func reference(_ name: String) throws -> String {
        try String(contentsOf: url("\(name).reference", "txt"), encoding: .utf8)
    }

    static func events(_ name: String) throws -> [RecordedRecognitionEvent] {
        try JSONDecoder().decode([RecordedRecognitionEvent].self, from: Data(contentsOf: url("\(name).analyzer-events", "json")))
    }

    private final class FixtureAnchor {}
}
