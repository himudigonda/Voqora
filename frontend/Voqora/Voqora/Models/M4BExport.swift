import CoreMedia
import Foundation

nonisolated struct M4BChapter: Equatable, Sendable {
    let title: String
    let startSeconds: Double
}

nonisolated struct M4BExportRequest: Equatable, Sendable {
    static let bitrateRange = 48000 ... 128_000
    static let defaultBitrate = 64000

    let sources: [URL]
    let chapters: [M4BChapter]
    let title: String
    let author: String
    let album: String
    let cover: Data?
    let bitrate: Int
    let outputURL: URL

    init(
        sources: [URL],
        chapters: [M4BChapter],
        title: String,
        author: String,
        album: String? = nil,
        cover: Data? = nil,
        bitrate: Int = M4BExportRequest.defaultBitrate,
        outputURL: URL
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlbum = album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.sources = sources
        self.chapters = chapters
        self.title = trimmedTitle
        self.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        self.album = trimmedAlbum.isEmpty ? trimmedTitle : trimmedAlbum
        self.cover = cover
        self.bitrate = bitrate
        self.outputURL = outputURL
    }

    func validate(fileManager: FileManager = .default) throws {
        guard !sources.isEmpty else { throw M4BExportError.noSourceAudio }
        guard sources.allSatisfy({ $0.isFileURL && fileManager.fileExists(atPath: $0.path) }) else {
            throw M4BExportError.missingSourceFile
        }
        guard !title.isEmpty else { throw M4BExportError.missingTitle }
        guard Self.bitrateRange.contains(bitrate) else { throw M4BExportError.unsupportedBitrate }
        guard outputURL.isFileURL else { throw M4BExportError.couldNotSave }
    }
}

nonisolated enum M4BExportError: LocalizedError, Equatable {
    case noSourceAudio
    case missingSourceFile
    case missingTitle
    case unsupportedBitrate
    case unreadableAudio
    case chaptersUnsupported
    case encodingFailed
    case couldNotSave

    var errorDescription: String? {
        switch self {
        case .noSourceAudio: "There is no narration to export yet."
        case .missingSourceFile: "Voqora couldn't find this audiobook's narration on disk."
        case .missingTitle: "Give the audiobook a title before exporting it."
        case .unsupportedBitrate: "Choose an export quality between 48 and 128 kbps."
        case .unreadableAudio: "Voqora couldn't read this audiobook's narration."
        case .chaptersUnsupported: "This Mac couldn't add chapters to the audiobook file."
        case .encodingFailed: "Voqora couldn't encode the audiobook. Try again."
        case .couldNotSave: "Voqora couldn't save the audiobook to that location."
        }
    }

    var failureCode: String {
        switch self {
        case .noSourceAudio: "m4b_no_source"
        case .missingSourceFile: "m4b_missing_source"
        case .missingTitle: "m4b_missing_title"
        case .unsupportedBitrate: "m4b_unsupported_bitrate"
        case .unreadableAudio: "m4b_unreadable_audio"
        case .chaptersUnsupported: "m4b_chapters_unsupported"
        case .encodingFailed: "m4b_encoding_failed"
        case .couldNotSave: "m4b_could_not_save"
        }
    }
}

nonisolated struct M4BChapterTimeline: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let title: String
        let start: Double
        let end: Double
    }

    static let minimumSpacingSeconds = 1.0
    static let maximumTitleLength = 256

    let entries: [Entry]

    init(chapters: [M4BChapter], duration: Double, fallbackTitle: String) {
        guard duration.isFinite, duration > 0 else {
            entries = []
            return
        }
        let starts = Self.orderedStarts(chapters, duration: duration, fallbackTitle: fallbackTitle)
        entries = starts.enumerated().map { index, chapter in
            let end = index + 1 < starts.count ? starts[index + 1].startSeconds : duration
            return Entry(title: chapter.title, start: chapter.startSeconds, end: end)
        }
    }

    private static func orderedStarts(_ chapters: [M4BChapter], duration: Double, fallbackTitle: String) -> [M4BChapter] {
        let candidates = chapters
            .filter { $0.startSeconds.isFinite && $0.startSeconds < duration }
            .map { M4BChapter(title: cleanTitle($0.title, fallback: fallbackTitle), startSeconds: max(0, $0.startSeconds)) }
            .sorted { $0.startSeconds < $1.startSeconds }
        var ordered: [M4BChapter] = []
        for chapter in candidates {
            if let previous = ordered.last, chapter.startSeconds - previous.startSeconds < minimumSpacingSeconds {
                continue
            }
            ordered.append(chapter)
        }
        guard let first = ordered.first else {
            return [M4BChapter(title: cleanTitle(fallbackTitle, fallback: "Chapter 1"), startSeconds: 0)]
        }
        if first.startSeconds < minimumSpacingSeconds {
            ordered[0] = M4BChapter(title: first.title, startSeconds: 0)
        } else {
            ordered.insert(M4BChapter(title: cleanTitle(fallbackTitle, fallback: "Opening"), startSeconds: 0), at: 0)
        }
        return ordered
    }

    private static func cleanTitle(_ title: String, fallback: String) -> String {
        let collapsed = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let limited = String(collapsed.prefix(maximumTitleLength))
        return limited.isEmpty ? fallback : limited
    }
}

nonisolated enum M4BChapterText {
    private static let encodingBox: [UInt8] = [0, 0, 0, 12, 0x65, 0x6E, 0x63, 0x64, 0, 0, 1, 0]

    static func samplePayload(for title: String) -> Data {
        let text = Data(title.utf8.prefix(Int(UInt16.max)))
        var payload = Data([UInt8(text.count >> 8), UInt8(text.count & 0xFF)])
        payload.append(text)
        payload.append(contentsOf: encodingBox)
        return payload
    }
}

nonisolated enum M4BArtworkFormat: Equatable, Sendable {
    case jpeg
    case png

    private static let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF]
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    init?(data: Data) {
        if data.starts(with: Self.jpegSignature) {
            self = .jpeg
        } else if data.starts(with: Self.pngSignature) {
            self = .png
        } else {
            return nil
        }
    }

    var metadataDataType: String {
        switch self {
        case .jpeg: kCMMetadataBaseDataType_JPEG as String
        case .png: kCMMetadataBaseDataType_PNG as String
        }
    }
}
