import Foundation

enum TextProcessor {
    struct Options {
        var cleanURLs: Bool
        var cleanHandles: Bool
        var fixLigatures: Bool
        var expandAbbr: Bool
        var expandNumbers: Bool = false
        var stripMarkdown: Bool = true
    }

    static func sanitize(_ text: String, options: Options) -> String {
        var result = text

        if options.stripMarkdown {
            result = stripMarkdownSyntax(result)
        }

        result = result.replacingOccurrences(of: "([a-zA-Z])- [\\r\\n]+([a-zA-Z])", with: "$1$2", options: .regularExpression)
        result = result.replacingOccurrences(of: "([a-zA-Z])-\\s+[\\r\\n]+([a-zA-Z])", with: "$1$2", options: .regularExpression)

        if options.fixLigatures {
            result = result.replacingOccurrences(of: "f i", with: "fi")
            result = result.replacingOccurrences(of: "f l", with: "fl")
            result = result.replacingOccurrences(of: "f f", with: "ff")
            result = result.replacingOccurrences(of: "n t", with: "nt")
            result = result.replacingOccurrences(of: "f j", with: "fj")
        }

        if options.cleanURLs {
            let regex = try? NSRegularExpression(pattern: "https?://\\S+", options: .caseInsensitive)
            result = regex?.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "link") ?? result
        }

        if options.cleanHandles {
            result = result.replacingOccurrences(of: "@\\w+", with: "", options: .regularExpression)
        }

        if options.expandAbbr {
            let abbr = [
                "e.g.": "for example",
                "i.e.": "that is",
                "etc.": "etcetera",
                "vs.": "versus",
                "st.": "street",
                "apt.": "apartment",
                "fig.": "figure",
                "figs.": "figures",
                "vol.": "volume",
                "no.": "number",
                "sec.": "section",
                "eq.": "equation",
                "eqs.": "equations",
                "ref.": "reference",
                "refs.": "references",
                "ch.": "chapter",
                "pp.": "pages",
                "p.": "page",
            ]
            for (k, v) in abbr {
                let escapedKey = k.replacingOccurrences(of: ".", with: "\\.")
                let pattern = "\\b\(escapedKey)"

                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    result = regex.stringByReplacingMatches(
                        in: result,
                        range: NSRange(result.startIndex..., in: result),
                        withTemplate: v
                    )
                }
            }
        }

        if options.expandNumbers {
            result = normalizeNumbers(result)
        }

        let symbols = ["\u{FFFC}", "￼", "•", "●", "▪", "◦", "‣", "⁃", "□", "▪"]
        for s in symbols {
            result = result.replacingOccurrences(of: s, with: "")
        }

        result = result.replacingOccurrences(of: "(\\n\\s*){2,}", with: "\n", options: .regularExpression)

        let cleaned = result.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripMarkdownSyntax(_ text: String) -> String {
        var result = text

        func replace(_ pattern: String, with template: String, in s: String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return s }
            return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }

        result = replace("```[a-zA-Z0-9]*\\n?", with: "", in: result)

        result = replace("!?\\[([^\\]]*)\\]\\([^\\)]*\\)", with: "$1", in: result)

        result = replace("^#{1,6}\\s*", with: "", in: result)

        result = replace("^>\\s?", with: "", in: result)

        result = replace("^(-{3,}|\\*{3,}|_{3,})\\s*$", with: "", in: result)

        result = replace("</?[A-Za-z][A-Za-z0-9-]*(?:\\s[^<>\\n]*)?/?>", with: "", in: result)

        result = replace("^\\s*[-*+]\\s+", with: "", in: result)

        result = replace("^\\s*\\d+[.)]\\s+", with: "", in: result)

        result = replace("^\\[[ xX]\\]\\s*", with: "", in: result)

        result = replace("^={2,}\\s*$", with: "", in: result)

        result = replace("^\\s*\\|?[\\s:|-]*\\|[\\s:|-]*$", with: "", in: result)
        result = result.replacingOccurrences(of: "|", with: " ")

        result = replace("(\\*\\*\\*|___)(.+?)\\1", with: "$2", in: result)
        result = replace("(\\*\\*|__)(.+?)\\1", with: "$2", in: result)
        result = replace("(?<![\\*\\w])\\*(?!\\s)([^\\*\\n]+?)(?<!\\s)\\*(?![\\*\\w])", with: "$1", in: result)
        result = replace("(?<![\\w_])_(?!\\s)([^_\\n]+?)(?<!\\s)_(?![\\w_])", with: "$1", in: result)
        result = replace("~~(.+?)~~", with: "$1", in: result)

        result = replace("`([^`]*)`", with: "$1", in: result)
        result = result.replacingOccurrences(of: "`", with: "")

        return result
    }

    private static let spellOutFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    private static func normalizeNumbers(_ text: String) -> String {
        var result = text

        let ordinalMap = ["1st": "first", "2nd": "second", "3rd": "third", "4th": "fourth",
                          "5th": "fifth", "6th": "sixth", "7th": "seventh", "8th": "eighth",
                          "9th": "ninth", "10th": "tenth", "11th": "eleventh", "12th": "twelfth",
                          "13th": "thirteenth", "14th": "fourteenth", "15th": "fifteenth",
                          "20th": "twentieth", "30th": "thirtieth", "100th": "hundredth"]
        for (k, v) in ordinalMap {
            result = result.replacingOccurrences(of: "\\b\(k)\\b", with: v, options: .regularExpression)
        }
        if let regex = try? NSRegularExpression(pattern: "\\b(\\d+)(?:st|nd|rd|th)\\b") {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        if let regex = try? NSRegularExpression(pattern: "\\b(\\d+(?:\\.\\d+)?)%") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range(at: 1), in: result),
                      let num = Double(result[range]),
                      let word = spellOutFormatter.string(from: NSNumber(value: num)) else { continue }
                let fullRange = Range(match.range, in: result)!
                result.replaceSubrange(fullRange, with: "\(word) percent")
            }
        }

        if let regex = try? NSRegularExpression(pattern: "\\$(\\d+)(?:\\.(\\d{2}))?\\b") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let dollarsRange = Range(match.range(at: 1), in: result),
                      let dollars = Int(result[dollarsRange]),
                      let dollarsWord = spellOutFormatter.string(from: NSNumber(value: dollars)) else { continue }
                var replacement = "\(dollarsWord) dollar\(dollars == 1 ? "" : "s")"
                if match.numberOfRanges > 2, let centsRange = Range(match.range(at: 2), in: result),
                   let cents = Int(result[centsRange]), cents > 0,
                   let centsWord = spellOutFormatter.string(from: NSNumber(value: cents))
                {
                    replacement += " and \(centsWord) cent\(cents == 1 ? "" : "s")"
                }
                let fullRange = Range(match.range, in: result)!
                result.replaceSubrange(fullRange, with: replacement)
            }
        }

        if let regex = try? NSRegularExpression(pattern: "\\b(\\d{1,3}(?:,\\d{3})+)\\b") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let stripped = String(result[range]).replacingOccurrences(of: ",", with: "")
                if let num = Double(stripped),
                   let word = spellOutFormatter.string(from: NSNumber(value: num))
                {
                    result.replaceSubrange(range, with: word)
                }
            }
        }

        if let regex = try? NSRegularExpression(pattern: "\\bv?(\\d+(?:\\.\\d+){2,})\\b") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let raw = String(result[range]).trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let spoken = raw.split(separator: ".").compactMap {
                    spellOutFormatter.string(from: NSNumber(value: Int($0) ?? 0))
                }.joined(separator: " point ")
                result.replaceSubrange(range, with: spoken)
            }
        }

        if let regex = try? NSRegularExpression(pattern: "\\b(\\d+\\.\\d+)\\b") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result),
                      let num = Double(result[range]),
                      let word = spellOutFormatter.string(from: NSNumber(value: num)) else { continue }
                result.replaceSubrange(range, with: word)
            }
        }

        if let regex = try? NSRegularExpression(pattern: "\\b(\\d+)\\b") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result),
                      let num = Int(result[range]),
                      let word = spellOutFormatter.string(from: NSNumber(value: num)) else { continue }
                result.replaceSubrange(range, with: word)
            }
        }

        return result
    }
}
