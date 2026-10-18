import Combine
import Foundation

nonisolated struct PodcastDraft: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var script: PodcastScript
    var updatedAt: Date
    var basedOnBookID: String?

    init(id: UUID = UUID(), script: PodcastScript, updatedAt: Date = Date(), basedOnBookID: String? = nil) {
        self.id = id
        self.script = script
        self.updatedAt = updatedAt
        self.basedOnBookID = basedOnBookID
    }

    enum CodingKeys: String, CodingKey {
        case id, script
        case updatedAt = "updated_at"
        case basedOnBookID = "based_on_book_id"
    }
}

final class StudioDraftStore: ObservableObject {
    static let capacity = 100
    private static let schemaVersion = 1

    @Published private(set) var drafts: [PodcastDraft] = []
    @Published private(set) var persistenceError: String?

    private let storageURL: URL

    private struct StoredFile: Encodable {
        let version: Int
        let drafts: [PodcastDraft]
    }

    private struct LoadedFile: Decodable {
        let drafts: [LossyDraft]
    }

    private struct LossyDraft: Decodable {
        let draft: PodcastDraft?

        init(from decoder: Decoder) throws {
            draft = try? PodcastDraft(from: decoder)
        }
    }

    private static func defaultStorageURL() -> URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID)
            .appendingPathComponent("studio-drafts.json")
    }

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        load()
    }

    func draft(withID id: UUID) -> PodcastDraft? {
        drafts.first { $0.id == id }
    }

    @discardableResult
    func save(_ draft: PodcastDraft) -> Bool {
        var updated = drafts.filter { $0.id != draft.id }
        updated.insert(draft, at: 0)
        updated.sort { $0.updatedAt > $1.updatedAt }
        drafts = Array(updated.prefix(Self.capacity))
        return persist()
    }

    func delete(_ id: UUID) {
        drafts.removeAll { $0.id == id }
        persist()
    }

    func retryPersistence() {
        persist()
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let file = StoredFile(version: Self.schemaVersion, drafts: drafts)
            try encoder.encode(file).write(to: storageURL, options: .atomic)
            persistenceError = nil
            return true
        } catch {
            VoqoraLog.warn("StudioDraftStore", "Draft save failed", ["failureCode": "studio_draft_save_failed"])
            persistenceError = "Voqora couldn't save your scripts. Your changes stay open until you quit."
            return false
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(LoadedFile.self, from: data)
            drafts = file.drafts.compactMap(\.draft).sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            VoqoraLog.warn("StudioDraftStore", "Draft file unreadable", ["failureCode": "studio_draft_load_failed"])
            let backup = storageURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: storageURL, to: backup)
            persistenceError = "Voqora couldn't read your saved scripts. It kept a copy of the file and started fresh."
        }
    }
}
