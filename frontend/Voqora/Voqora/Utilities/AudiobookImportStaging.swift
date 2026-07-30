import Foundation

/// Owns the short-lived local copy made from a Finder security-scoped document.
///
/// The audiobook backend receives the file immediately, but the estimate sheet
/// also needs it for the cover preview. Keeping that copy in a unique folder
/// avoids name collisions and gives cancellation one narrow, safe cleanup
/// target.
enum AudiobookImportStaging {
    static let directoryPrefix = "VoqoraImport-"

    /// The shared product contract for every document entry point: importer,
    /// drag and drop, upload MIME type, and analytics must agree on this set.
    nonisolated static let supportedExtensions: Set<String> = ["pdf", "txt", "docx", "md"]
    nonisolated static let supportedFormatsDescription = "PDF, TXT, DOCX, and Markdown"

    enum StagingError: LocalizedError {
        case unsupportedFile

        var errorDescription: String? {
            switch self {
            case .unsupportedFile:
                return "Voqora audiobooks support \(supportedFormatsDescription) files."
            }
        }
    }

    nonisolated static func supports(_ sourceURL: URL) -> Bool {
        supportedExtensions.contains(sourceURL.pathExtension.lowercased())
    }

    static func stageDocument(
        from sourceURL: URL,
        in root: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard supports(sourceURL) else {
            throw StagingError.unsupportedFile
        }

        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let directory = root.appendingPathComponent(
            "\(directoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        let stagedURL = directory.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceURL, to: stagedURL)
            return stagedURL
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    /// Removes only a Voqora-owned import directory directly below the chosen
    /// temporary root. A regular user file or a sibling temporary directory is
    /// never a valid cleanup target.
    static func discard(
        _ stagedURL: URL?,
        in root: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        guard let stagedURL else { return }
        let normalizedRoot = root.standardizedFileURL
        let directory = stagedURL.deletingLastPathComponent().standardizedFileURL
        guard directory.deletingLastPathComponent().standardizedFileURL == normalizedRoot,
              directory.lastPathComponent.hasPrefix(directoryPrefix) else { return }
        try? fileManager.removeItem(at: directory)
    }
}
