import AppKit
import UniformTypeIdentifiers

enum InboxDropReader {
    static let acceptedTypes: [UTType] = [.fileURL, .url, .plainText]

    static func accepts(_ provider: NSItemProvider) -> Bool {
        acceptedTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
    }

    static func links(from providers: [NSItemProvider]) async -> [URL] {
        var found: [URL] = []
        for provider in providers {
            if let url = await link(from: provider) {
                found.append(url)
            }
        }
        return found
    }

    static func link(from provider: NSItemProvider) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            guard let fileURL = await AudiobookImportStaging.fileURL(from: provider) else { return nil }
            return weblocLink(at: fileURL)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            return await loadURL(from: provider).flatMap(InboxLinkParser.validated)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return await loadText(from: provider).flatMap(InboxLinkParser.webURL(from:))
        }
        return nil
    }

    static func weblocLink(at fileURL: URL) -> URL? {
        guard InboxLinkParser.isWebloc(fileURL) else { return nil }
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= InboxLinkParser.maximumWeblocBytes,
              let data = try? Data(contentsOf: fileURL)
        else { return nil }
        return InboxLinkParser.webURL(fromWebloc: data)
    }

    static func pasteboardLink(from pasteboard: NSPasteboard) -> URL? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if url.isFileURL, let link = weblocLink(at: url) {
                    return link
                }
                if let link = InboxLinkParser.validated(url) {
                    return link
                }
            }
        }
        return pasteboard.string(forType: .string).flatMap(InboxLinkParser.webURL(from:))
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                let url = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? (item as? URL)
                continuation.resume(returning: url)
            }
        }
    }

    private static func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let text = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                continuation.resume(returning: text)
            }
        }
    }
}
