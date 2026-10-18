import AppKit
import UniformTypeIdentifiers

enum PronunciationFilePanels {
    static let maximumImportBytes = 1_048_576

    static func chooseImportFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import Pronunciations"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func chooseExportDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Pronunciations"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func readImport(from url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximumImportBytes else {
            throw UserFacingError(message: "Choose a pronunciation list up to 1 MB.")
        }
        return try Data(contentsOf: url)
    }
}
