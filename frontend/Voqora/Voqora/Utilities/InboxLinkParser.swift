import Foundation

nonisolated enum InboxLinkParser {
    static let maximumURLLength = 2048
    static let maximumWeblocBytes = 64 * 1024
    static let weblocExtension = "webloc"
    private static let maximumScannedCharacters = 10000
    private static let webSchemes: Set<String> = ["http", "https"]

    static func webURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains(where: \.isWhitespace), let direct = URL(string: trimmed), direct.scheme != nil {
            return validated(direct)
        }
        return detectedLink(in: String(trimmed.prefix(maximumScannedCharacters)))
    }

    static func validated(_ url: URL) -> URL? {
        guard url.absoluteString.count <= maximumURLLength,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              webSchemes.contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil
        else { return nil }
        return url
    }

    static func webURL(fromWebloc data: Data) -> URL? {
        guard data.count <= maximumWeblocBytes,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let link = dictionary["URL"] as? String
        else { return nil }
        return webURL(from: link)
    }

    static func isWebloc(_ fileURL: URL) -> Bool {
        fileURL.isFileURL && fileURL.pathExtension.lowercased() == weblocExtension
    }

    static func matchKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.port == 80 || components.port == 443 {
            components.port = nil
        }
        var key = components.string ?? url.absoluteString
        if key.hasSuffix("/") {
            key.removeLast()
        }
        if key.hasPrefix("http://") {
            key = "https://" + key.dropFirst("http://".count)
        }
        return key
    }

    static func displayHost(of url: URL) -> String? {
        guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func detectedLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            if let url = match.url.flatMap(validated) {
                return url
            }
        }
        return nil
    }
}
