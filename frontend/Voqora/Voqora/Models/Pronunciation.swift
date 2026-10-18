import Foundation

nonisolated enum PronunciationRules {
    static let maxMatchLength = 100
    static let maxReplacementLength = 200
    static let maxTestTextLength = 5000
    static let maxEntries = 500

    static func isHexID(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { ("0" ... "9").contains($0) || ("a" ... "f").contains($0) }
    }

    static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
        }
    }
}

nonisolated enum PronunciationScope: Hashable, Sendable {
    case global
    case book(String)

    static let globalRawValue = "global"

    init?(rawValue: String) {
        if rawValue == Self.globalRawValue {
            self = .global
        } else if PronunciationRules.isHexID(rawValue) {
            self = .book(rawValue)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .global: Self.globalRawValue
        case let .book(id): id
        }
    }

    var bookID: String? {
        if case let .book(id) = self {
            return id
        }
        return nil
    }
}

nonisolated struct PronunciationEntry: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let match: String
    let replacement: String
    let caseSensitive: Bool
    let wholeWord: Bool
    let scope: String
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case match
        case replacement
        case caseSensitive = "case_sensitive"
        case wholeWord = "whole_word"
        case scope
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var scopeValue: PronunciationScope {
        PronunciationScope(rawValue: scope) ?? .global
    }

    func matches(query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return match.localizedCaseInsensitiveContains(needle) || replacement.localizedCaseInsensitiveContains(needle)
    }
}

nonisolated struct PronunciationList: Decodable, Sendable {
    let version: Int
    let maxEntries: Int
    let entries: [PronunciationEntry]

    enum CodingKeys: String, CodingKey {
        case version
        case maxEntries = "max_entries"
        case entries
    }
}

nonisolated struct PronunciationRequest: Encodable, Equatable, Sendable {
    let match: String
    let replacement: String
    let caseSensitive: Bool
    let wholeWord: Bool
    let scope: String

    enum CodingKeys: String, CodingKey {
        case match
        case replacement
        case caseSensitive = "case_sensitive"
        case wholeWord = "whole_word"
        case scope
    }
}

nonisolated struct PronunciationDraft: Equatable, Sendable {
    var match: String
    var replacement: String
    var caseSensitive: Bool
    var wholeWord: Bool
    var scope: PronunciationScope

    init(
        match: String = "",
        replacement: String = "",
        caseSensitive: Bool = false,
        wholeWord: Bool = true,
        scope: PronunciationScope = .global
    ) {
        self.match = match
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.scope = scope
    }

    init(entry: PronunciationEntry) {
        self.init(
            match: entry.match,
            replacement: entry.replacement,
            caseSensitive: entry.caseSensitive,
            wholeWord: entry.wholeWord,
            scope: entry.scopeValue
        )
    }

    private var trimmedMatch: String {
        match.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedReplacement: String {
        replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var validationMessage: String? {
        let match = trimmedMatch
        let replacement = trimmedReplacement
        if match.isEmpty {
            return "Enter the text to replace."
        }
        if match.count > PronunciationRules.maxMatchLength {
            return "Keep the text to replace to \(PronunciationRules.maxMatchLength) characters or fewer."
        }
        if replacement.count > PronunciationRules.maxReplacementLength {
            return "Keep the replacement to \(PronunciationRules.maxReplacementLength) characters or fewer."
        }
        if PronunciationRules.containsControlCharacters(match) || PronunciationRules.containsControlCharacters(replacement) {
            return "Use a single line of text without line breaks."
        }
        return nil
    }

    var isValid: Bool {
        validationMessage == nil
    }

    var request: PronunciationRequest {
        PronunciationRequest(
            match: trimmedMatch,
            replacement: trimmedReplacement,
            caseSensitive: caseSensitive,
            wholeWord: wholeWord,
            scope: scope.rawValue
        )
    }
}

nonisolated struct PronunciationTestRequest: Encodable, Equatable, Sendable {
    let text: String
    let bookID: String?

    enum CodingKeys: String, CodingKey {
        case text
        case bookID = "book_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(bookID, forKey: .bookID)
    }
}

nonisolated struct PronunciationTestResult: Decodable, Equatable, Sendable {
    let text: String
    let spoken: String
    let replacements: Int
    let version: Int
}

nonisolated struct PronunciationTransferFile: Codable, Equatable, Sendable {
    nonisolated struct Item: Codable, Equatable, Sendable {
        let match: String
        let replacement: String
        let caseSensitive: Bool
        let wholeWord: Bool

        enum CodingKeys: String, CodingKey {
            case match
            case replacement
            case caseSensitive = "case_sensitive"
            case wholeWord = "whole_word"
        }
    }

    static let currentFormat = "voqora.pronunciations"
    static let currentVersion = 1

    let format: String
    let version: Int
    let entries: [Item]

    init(entries: [PronunciationEntry]) {
        format = Self.currentFormat
        version = Self.currentVersion
        self.entries = entries.map {
            Item(match: $0.match, replacement: $0.replacement, caseSensitive: $0.caseSensitive, wholeWord: $0.wholeWord)
        }
    }

    nonisolated enum TransferError: LocalizedError, Equatable {
        case unreadable
        case unsupportedVersion
        case empty
        case tooMany

        var errorDescription: String? {
            switch self {
            case .unreadable: "That file isn't a Voqora pronunciation list."
            case .unsupportedVersion: "That pronunciation list was made by a newer version of Voqora."
            case .empty: "That pronunciation list has no entries."
            case .tooMany: "That list has more than \(PronunciationRules.maxEntries) entries."
            }
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> PronunciationTransferFile {
        guard let file = try? JSONDecoder().decode(PronunciationTransferFile.self, from: data),
              file.format == currentFormat
        else {
            throw TransferError.unreadable
        }
        guard file.version <= currentVersion else { throw TransferError.unsupportedVersion }
        guard !file.entries.isEmpty else { throw TransferError.empty }
        guard file.entries.count <= PronunciationRules.maxEntries else { throw TransferError.tooMany }
        return file
    }

    func drafts(in scope: PronunciationScope) -> [PronunciationDraft] {
        entries.map {
            PronunciationDraft(
                match: $0.match,
                replacement: $0.replacement,
                caseSensitive: $0.caseSensitive,
                wholeWord: $0.wholeWord,
                scope: scope
            )
        }
    }
}
