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

        // 1. Hyphenation Fix
        // Detects "word- \n next" and joins them
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
            // Replaced with a bare word, not "[link]". The bracketed form was
            // substituted *after* stripMarkdownSyntax had already run, so it
            // introduced fresh bracket characters that nothing downstream
            // removed — the cleanup step handing the phonemizer new punctuation
            // to vocalize.
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
                // FIX: Escape the period and enforce a Word Boundary (\b)
                // This ensures "host." doesn't trigger the "st." replacement.
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

        // Final purification: Remove placeholders and purely symbolic noise
        let symbols = ["\u{FFFC}", "￼", "•", "●", "▪", "◦", "‣", "⁃", "□", "▪"]
        for s in symbols {
            result = result.replacingOccurrences(of: s, with: "")
        }

        // Remove multiple consecutive newlines which often represent page gaps
        result = result.replacingOccurrences(of: "(\\n\\s*){2,}", with: "\n", options: .regularExpression)

        let cleaned = result.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Reduce multiple spaces to single space
        return cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips Markdown syntax down to the text a listener actually cares about,
    /// so a shortcut fired over raw Markdown source (a README, notes, GitHub
    /// content) doesn't read punctuation aloud — "asterisk", "pound", etc.
    /// Order matters: links/images before emphasis (bracket contents can
    /// contain `*`/`_`), and emphasis markers widest-to-narrowest so `***x***`
    /// doesn't get half-matched by the `*x*` pattern first.
    private static func stripMarkdownSyntax(_ text: String) -> String {
        var result = text

        func replace(_ pattern: String, with template: String, in s: String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return s }
            return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }

        // Fenced code blocks: drop the ``` delimiters and any language tag.
        result = replace("```[a-zA-Z0-9]*\\n?", with: "", in: result)

        // Images/links: ![alt](url) and [text](url) -> just the visible text.
        result = replace("!?\\[([^\\]]*)\\]\\([^\\)]*\\)", with: "$1", in: result)

        // Headings: leading #'s at the start of a line.
        result = replace("^#{1,6}\\s*", with: "", in: result)

        // Blockquotes: leading > at the start of a line.
        result = replace("^>\\s?", with: "", in: result)

        // Horizontal rules on their own line.
        result = replace("^(-{3,}|\\*{3,}|_{3,})\\s*$", with: "", in: result)

        // HTML tags — the backend twin strips these; this one never did, so a
        // selection lifted from a README narrated "<br>" and friends.
        result = replace("</?[A-Za-z][A-Za-z0-9-]*(?:\\s[^<>\\n]*)?/?>", with: "", in: result)

        // Unordered list markers at the start of a line.
        result = replace("^\\s*[-*+]\\s+", with: "", in: result)

        // Ordered list markers ("1.", "2)"). Without this the number survived
        // and normalizeNumbers then rewrote "1." to the spoken word "one."
        result = replace("^\\s*\\d+[.)]\\s+", with: "", in: result)

        // Task-list checkboxes left behind by the list-marker rules above.
        result = replace("^\\[[ xX]\\]\\s*", with: "", in: result)

        // Setext heading underlines. The rule above covers "---"/"***"/"___"
        // but not "===", so a setext H1 underline was read as a run of "equals".
        result = replace("^={2,}\\s*$", with: "", in: result)

        // Table pipes. Not handled at all before, so "|" reached the phonemizer.
        result = replace("^\\s*\\|?[\\s:|-]*\\|[\\s:|-]*$", with: "", in: result)
        result = result.replacingOccurrences(of: "|", with: " ")

        // Emphasis: ***bold italic***, **bold**, *italic*, __bold__, _italic_, ~~strikethrough~~.
        result = replace("(\\*\\*\\*|___)(.+?)\\1", with: "$2", in: result)
        result = replace("(\\*\\*|__)(.+?)\\1", with: "$2", in: result)
        // Single-delimiter emphasis is anchored: the delimiter must sit at a
        // word boundary and hug its content, and the content may not contain
        // another delimiter. The old "(\\*|_)(.+?)\\1" paired the first
        // delimiter on a line with the nearest later one *anywhere* on that
        // line, which silently corrupted ordinary text rather than markup:
        //   "value_a and value_b" -> "valuea and valueb"
        //   "5 * 3 and 4 * 8"     -> "5 3 and 4 8"   (operators deleted)
        //   "get_user_name"       -> "getusername"
        result = replace("(?<![\\*\\w])\\*(?!\\s)([^\\*\\n]+?)(?<!\\s)\\*(?![\\*\\w])", with: "$1", in: result)
        result = replace("(?<![\\w_])_(?!\\s)([^_\\n]+?)(?<!\\s)_(?![\\w_])", with: "$1", in: result)
        result = replace("~~(.+?)~~", with: "$1", in: result)

        // Inline code spans, then any stray unmatched backtick left behind by
        // an unbalanced fence.
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

        // 1. Known ordinals
        let ordinalMap = ["1st":"first","2nd":"second","3rd":"third","4th":"fourth",
                          "5th":"fifth","6th":"sixth","7th":"seventh","8th":"eighth",
                          "9th":"ninth","10th":"tenth","11th":"eleventh","12th":"twelfth",
                          "13th":"thirteenth","14th":"fourteenth","15th":"fifteenth",
                          "20th":"twentieth","30th":"thirtieth","100th":"hundredth"]
        for (k, v) in ordinalMap {
            result = result.replacingOccurrences(of: "\\b\(k)\\b", with: v, options: .regularExpression)
        }
        // Generic ordinals not in map: strip suffix so integer pass handles them
        if let regex = try? NSRegularExpression(pattern: "\\b(\\d+)(?:st|nd|rd|th)\\b") {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        // 2. Percentages: "50%" → "fifty percent"
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

        // 3. Currency: "$3.50" → "three dollars and fifty cents"
        if let regex = try? NSRegularExpression(pattern: "\\$(\\d+)(?:\\.(\\d{2}))?\\b") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let dollarsRange = Range(match.range(at: 1), in: result),
                      let dollars = Int(result[dollarsRange]),
                      let dollarsWord = spellOutFormatter.string(from: NSNumber(value: dollars)) else { continue }
                var replacement = "\(dollarsWord) dollar\(dollars == 1 ? "" : "s")"
                if match.numberOfRanges > 2, let centsRange = Range(match.range(at: 2), in: result),
                   let cents = Int(result[centsRange]), cents > 0,
                   let centsWord = spellOutFormatter.string(from: NSNumber(value: cents)) {
                    replacement += " and \(centsWord) cent\(cents == 1 ? "" : "s")"
                }
                let fullRange = Range(match.range, in: result)!
                result.replaceSubrange(fullRange, with: replacement)
            }
        }

        // 4. Comma-separated integers: "3,600" → "three thousand six hundred"
        if let regex = try? NSRegularExpression(pattern: "\\b(\\d{1,3}(?:,\\d{3})+)\\b") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let stripped = String(result[range]).replacingOccurrences(of: ",", with: "")
                if let num = Double(stripped),
                   let word = spellOutFormatter.string(from: NSNumber(value: num)) {
                    result.replaceSubrange(range, with: word)
                }
            }
        }

        // 5. Dotted version strings: "v1.2.3", "1.2.3" → "one point two point three"
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

        // 6. Plain decimals: "3.14" → "three point one four"
        if let regex = try? NSRegularExpression(pattern: "\\b(\\d+\\.\\d+)\\b") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result),
                      let num = Double(result[range]),
                      let word = spellOutFormatter.string(from: NSNumber(value: num)) else { continue }
                result.replaceSubrange(range, with: word)
            }
        }

        // 7. Plain integers: "42" → "forty-two"
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
