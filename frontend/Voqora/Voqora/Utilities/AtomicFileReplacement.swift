import Foundation

nonisolated enum AtomicFileReplacement {
    static func makeWorkspace(near destination: URL, fileManager: FileManager = .default) throws -> URL {
        if let replacement = try? fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination,
            create: true
        ) {
            return replacement
        }
        let fallback = fileManager.temporaryDirectory
            .appendingPathComponent("Voqora-export-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static func moveIntoPlace(_ source: URL, at destination: URL, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: source)
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    static func copy(_ source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        let workspace = try makeWorkspace(near: destination, fileManager: fileManager)
        defer { discard(workspace, fileManager: fileManager) }
        let staged = workspace.appendingPathComponent(destination.lastPathComponent)
        try fileManager.copyItem(at: source, to: staged)
        try moveIntoPlace(staged, at: destination, fileManager: fileManager)
    }

    static func discard(_ workspace: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: workspace)
    }
}
