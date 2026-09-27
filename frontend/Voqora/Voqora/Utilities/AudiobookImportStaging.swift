import Foundation
import UniformTypeIdentifiers

enum AudiobookImportStaging {
    static let directoryPrefix = "VoqoraImport-"

    nonisolated static let supportedExtensions: Set<String> = ["pdf", "txt", "docx", "md"]
    nonisolated static let supportedFormatsDescription = "PDF, Word, text, and Markdown"

    static var documentTypes: [UTType] {
        [.pdf, .plainText, UTType(importedAs: "org.openxmlformats.wordprocessingml.document")]
            + [UTType(filenameExtension: "md")].compactMap(\.self)
    }

    static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? (item as? URL)
                continuation.resume(returning: url)
            }
        }
    }

    enum StagingError: LocalizedError {
        case unsupportedFile

        var errorDescription: String? {
            switch self {
            case .unsupportedFile:
                "Voqora audiobooks support \(supportedFormatsDescription) files."
            }
        }
    }

    nonisolated static func supports(_ sourceURL: URL) -> Bool {
        supportedExtensions.contains(sourceURL.pathExtension.lowercased())
    }

    nonisolated static func strippingSupportedExtension(from name: String) -> String {
        for ext in supportedExtensions where name.lowercased().hasSuffix(".\(ext)") {
            return String(name.dropLast(ext.count + 1))
        }
        return name
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
        defer {
            if scoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

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
