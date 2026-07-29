import Combine
import Foundation

class HistoryManager: ObservableObject {
    @Published var history: [HistoryEntry] = []

    private var url: URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID)
            .appendingPathComponent("history.json")
    }

    init() {
        // Ensure directory exists
        let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(bundleID)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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

    private func saveHistory() {
        if let encoded = try? JSONEncoder().encode(history) {
            try? encoded.write(to: url)
        }
    }

    private func loadHistory() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        {
            history = decoded
        }
    }
}
