import Foundation

enum AudiobookCreateStaging {
    static let defaultTextTitle = "Pasted Text"
    static let maximumFileNameLength = 80

    static func fileName(forTitle title: String?, fallback: String) -> String {
        let cleaned = (title ?? "").unicodeScalars
            .map { $0.properties.generalCategory == .control || "/\\:".unicodeScalars.contains($0) ? " " : Character($0) }
        let collapsed = String(cleaned).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let limited = String(collapsed.prefix(maximumFileNameLength)).trimmingCharacters(in: .whitespaces)
        let stripped = limited.hasPrefix(".") ? String(limited.drop(while: { $0 == "." })) : limited
        return stripped.isEmpty ? fallback : stripped
    }

    static func stageText(
        _ text: String,
        title: String?,
        in root: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> URL {
        let name = fileName(forTitle: title, fallback: defaultTextTitle)
        return try write(into: root, fileManager: fileManager, name: "\(name).txt") { try Data(text.utf8).write(to: $0) }
    }

    static func stageCopy(
        of staged: URL,
        titled title: String,
        in root: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> URL {
        let fallback = AudiobookImportStaging.strippingSupportedExtension(from: staged.lastPathComponent)
        let name = fileName(forTitle: title, fallback: fallback)
        let ext = staged.pathExtension
        let fileName = ext.isEmpty ? name : "\(name).\(ext)"
        return try write(into: root, fileManager: fileManager, name: fileName) { try fileManager.copyItem(at: staged, to: $0) }
    }

    private static func write(
        into root: URL,
        fileManager: FileManager,
        name: String,
        body: (URL) throws -> Void
    ) throws -> URL {
        let directory = root.appendingPathComponent("\(AudiobookImportStaging.directoryPrefix)\(UUID().uuidString)", isDirectory: true)
        let target = directory.appendingPathComponent(name)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try body(target)
            return target
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }
}
