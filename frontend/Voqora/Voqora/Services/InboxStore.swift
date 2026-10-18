import Combine
import Foundation

final class InboxStore: ObservableObject {
    static let capacity = 500
    static let maximumTitleLength = 300
    static let maximumLabelLength = 200
    private static let indexFileName = "items.json"
    private static let articlesFolderName = "articles"

    enum Insertion: Equatable {
        case added(InboxItem)
        case existing(InboxItem)
    }

    enum StoreError: LocalizedError {
        case saveFailed

        var errorDescription: String? {
            Message.articleSaveFailed
        }
    }

    enum Message {
        static let articleSaveFailed = "Voqora could not save that article on this Mac. Check your free disk space and try again."
        static let prepareFailed = "Your Inbox could not be prepared on this Mac."
        static let saveFailed = "Your Inbox could not be saved. Recent changes stay available until Voqora quits."
        static let loadFailed = "Your saved Inbox could not be loaded. New articles can still be added."
    }

    @Published private(set) var items: [InboxItem] = []
    @Published private(set) var persistenceError: String?

    private let directory: URL
    private let fileManager: FileManager

    private var indexURL: URL {
        directory.appendingPathComponent(Self.indexFileName)
    }

    private var articlesURL: URL {
        directory.appendingPathComponent(Self.articlesFolderName, isDirectory: true)
    }

    static func defaultDirectory() -> URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    init(directory: URL? = nil, fileManager: FileManager? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        self.fileManager = fileManager ?? .default
        load()
    }

    func item(withID id: InboxItem.ID) -> InboxItem? {
        items.first { $0.id == id }
    }

    func item(matching url: URL) -> InboxItem? {
        let key = InboxLinkParser.matchKey(for: url)
        return items.first { InboxLinkParser.matchKey(for: $0.url) == key }
    }

    func add(_ article: ExtractedArticle, requestedURL: URL, at date: Date) throws -> Insertion {
        if let existing = item(matching: article.url) ?? item(matching: requestedURL) {
            return .existing(existing)
        }
        let newItem = InboxItem(
            id: UUID(),
            title: Self.cleaned(article.title, limit: Self.maximumTitleLength) ?? InboxLinkParser.displayHost(of: article.url) ?? "Untitled article",
            siteName: article.siteName.flatMap { Self.cleaned($0, limit: Self.maximumLabelLength) },
            byline: article.byline.flatMap { Self.cleaned($0, limit: Self.maximumLabelLength) },
            url: article.url,
            language: article.language,
            wordCount: max(0, article.wordCount),
            addedAt: date,
            progress: 0,
            isArchived: false
        )
        do {
            try prepareDirectories()
            let body = InboxArticleBody(text: article.text, markdown: article.markdown)
            try JSONEncoder().encode(body).write(to: bodyURL(for: newItem.id), options: .atomic)
        } catch {
            VoqoraLog.error("InboxStore", "Article body could not be saved", ["failureCode": "inbox_body_write_failed"])
            throw StoreError.saveFailed
        }
        var updated = [newItem] + items
        let evicted = Self.evictions(from: updated, capacity: Self.capacity)
        updated.removeAll { evicted.contains($0.id) }
        items = updated
        saveIndex()
        for id in evicted {
            removeBody(for: id)
        }
        return .added(newItem)
    }

    func body(for id: InboxItem.ID) -> InboxArticleBody? {
        guard let data = try? Data(contentsOf: bodyURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(InboxArticleBody.self, from: data)
    }

    func setProgress(_ progress: Double, for id: InboxItem.ID) {
        guard progress.isFinite else { return }
        let clamped = min(max(progress, 0), 1)
        update(id) { $0.progress = clamped }
    }

    func setArchived(_ archived: Bool, for id: InboxItem.ID) {
        update(id) { $0.isArchived = archived }
    }

    func delete(_ id: InboxItem.ID) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        saveIndex()
        removeBody(for: id)
    }

    func eraseAll() throws {
        items.removeAll()
        persistenceError = nil
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    func retryPersistence() {
        saveIndex()
    }

    static func evictions(from items: [InboxItem], capacity: Int) -> Set<InboxItem.ID> {
        let overflow = items.count - capacity
        guard overflow > 0 else { return [] }
        let oldestFirst = items.sorted { $0.addedAt < $1.addedAt }
        let archived = oldestFirst.filter(\.isArchived)
        let others = oldestFirst.filter { !$0.isArchived }
        return Set((archived + others).prefix(overflow).map(\.id))
    }

    static func cleaned(_ value: String, limit: Int) -> String? {
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(limit))
    }

    private func update(_ id: InboxItem.ID, change: (inout InboxItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        change(&item)
        guard item != items[index] else { return }
        items[index] = item
        saveIndex()
    }

    private func bodyURL(for id: InboxItem.ID) -> URL {
        articlesURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: articlesURL, withIntermediateDirectories: true)
    }

    private func removeBody(for id: InboxItem.ID) {
        try? fileManager.removeItem(at: bodyURL(for: id))
    }

    private func saveIndex() {
        do {
            try prepareDirectories()
            try JSONEncoder().encode(items).write(to: indexURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = Message.saveFailed
            VoqoraLog.error("InboxStore", "Inbox index could not be saved", ["failureCode": "inbox_index_write_failed"])
        }
    }

    private struct LossyItem: Decodable {
        let item: InboxItem?

        init(from decoder: Decoder) throws {
            item = try? InboxItem(from: decoder)
        }
    }

    private func load() {
        do {
            try prepareDirectories()
        } catch {
            persistenceError = Message.prepareFailed
            return
        }
        guard fileManager.fileExists(atPath: indexURL.path) else {
            removeOrphanedBodies(keeping: [])
            return
        }
        guard let data = try? Data(contentsOf: indexURL) else {
            persistenceError = Message.loadFailed
            return
        }
        do {
            let decoded = try JSONDecoder().decode([LossyItem].self, from: data).compactMap(\.item)
            var seen = Set<InboxItem.ID>()
            let unique = decoded.filter { seen.insert($0.id).inserted }
            items = Array(unique.sorted { $0.addedAt > $1.addedAt }.prefix(Self.capacity))
            removeOrphanedBodies(keeping: Set(items.map(\.id)))
        } catch {
            let backup = indexURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? fileManager.moveItem(at: indexURL, to: backup)
            persistenceError = Message.loadFailed
            VoqoraLog.warn("InboxStore", "Inbox index was unreadable and was set aside", ["failureCode": "inbox_index_unreadable"])
        }
    }

    private func removeOrphanedBodies(keeping ids: Set<InboxItem.ID>) {
        guard let files = try? fileManager.contentsOfDirectory(at: articlesURL, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
            if id.map({ !ids.contains($0) }) ?? true {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
