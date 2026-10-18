import Foundation

nonisolated enum LibraryTextDocument {
    static let directoryPrefix = "VoqoraText-"
    static let fallbackTitle = "Selected Text"
    static let maxTitleWords = 8
    static let maxTitleLength = 60

    private static let disallowedTitleCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")
        .union(.controlCharacters)

    static func title(for text: String) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .map { sanitizedTitle(String($0)) }
            .first { !$0.isEmpty }
        return firstLine ?? fallbackTitle
    }

    static func write(_ text: String, in root: URL, fileManager: FileManager = .default) throws -> URL {
        let directory = root.appendingPathComponent("\(directoryPrefix)\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("\(title(for: text)).txt")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private static func sanitizedTitle(_ line: String) -> String {
        let cleanedScalars = line.unicodeScalars.map { disallowedTitleCharacters.contains($0) ? " " : String($0) }
        let words = cleanedScalars.joined()
            .split(whereSeparator: \.isWhitespace)
            .prefix(maxTitleWords)
        let title = String(words.joined(separator: " ").prefix(maxTitleLength))
        return title.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }
}
