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
        let entry = HistoryEntry(text: text, voice: voice)
        history.insert(entry, at: 0)
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
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

    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoded = try JSONDecoder().decode([HistoryEntry].self, from: data)
            history = decoded
        } catch {
            persistenceError = "Existing history could not be loaded. New speech still works."
        }
    }
}
