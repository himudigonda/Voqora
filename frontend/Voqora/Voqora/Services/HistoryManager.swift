import Combine
import Foundation

class HistoryManager: ObservableObject {
    @Published var history: [HistoryEntry] = []
    @Published private(set) var persistenceError: String?

    private static func defaultStorageURL() -> URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID)
            .appendingPathComponent("history.json")
    }

    private let storageURL: URL
    static let recentEntryLimit = 500

    private struct LossyEntry: Decodable {
        let entry: HistoryEntry?
        init(from decoder: Decoder) throws {
            entry = try? HistoryEntry(from: decoder)
        }
    }

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        do {
            try FileManager.default.createDirectory(
                at: self.storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            persistenceError = "History could not be prepared on this Mac."
        }
        loadHistory()
    }

    func log(text: String, voice: String) {
        let repeated = history.filter { $0.text == text && $0.voice == voice }
        history.removeAll { $0.text == text && $0.voice == voice }
        history.insert(HistoryEntry(text: text, voice: voice, isFavorite: repeated.contains(where: \.isFavorite)), at: 0)
        history = Self.trimmed(history, keepingRecent: Self.recentEntryLimit)
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    func eraseAll() throws {
        history.removeAll()
        persistenceError = nil
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        try FileManager.default.removeItem(at: storageURL)
    }

    func delete(entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        saveHistory()
    }

    func toggleFavorite(entry: HistoryEntry) {
        if let index = history.firstIndex(where: { $0.id == entry.id }) {
            history[index].isFavorite.toggle()
            saveHistory()
        }
    }

    func retryPersistence() {
        saveHistory()
    }

    private func saveHistory() {
        do {
            let encoded = try JSONEncoder().encode(history)
            try encoded.write(to: storageURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = "History could not be saved. Your current session is still available."
        }
    }

    static func trimmed(_ entries: [HistoryEntry], keepingRecent limit: Int) -> [HistoryEntry] {
        var recent = 0
        return entries.filter { entry in
            if entry.isFavorite {
                return true
            }
            recent += 1
            return recent <= limit
        }
    }

    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        guard let data = try? Data(contentsOf: storageURL) else {
            persistenceError = "Existing history could not be loaded. New speech still works."
            return
        }
        do {
            history = try JSONDecoder().decode([LossyEntry].self, from: data).compactMap(\.entry)
        } catch {
            let backup = storageURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: storageURL, to: backup)
            persistenceError = "Existing history could not be loaded. New speech still works."
        }
    }
}
