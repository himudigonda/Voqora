import Combine
import Foundation

nonisolated struct DictationTranscript: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let createdAt: Date
    let localeIdentifier: String?
    var rawText: String?
}

final class DictationTranscriptStore: ObservableObject {
    static let capacity = 200

    @Published private(set) var transcripts: [DictationTranscript] = []
    @Published private(set) var persistenceError: String?

    private let storageURL: URL

    private struct LossyTranscript: Decodable {
        let transcript: DictationTranscript?

        init(from decoder: Decoder) throws {
            transcript = try? DictationTranscript(from: decoder)
        }
    }

    private static func defaultStorageURL() -> URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.himudigonda.Voqora"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID)
            .appendingPathComponent("dictation-transcripts.json")
    }

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        do {
            try FileManager.default.createDirectory(
                at: self.storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            persistenceError = "Dictation transcripts could not be prepared on this Mac."
        }
        load()
    }

    @discardableResult
    func add(_ text: String, rawText: String? = nil, localeIdentifier: String?, at date: Date = Date()) -> DictationTranscript? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let trimmedRaw = rawText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = DictationTranscript(
            id: UUID(),
            text: trimmed,
            createdAt: date,
            localeIdentifier: localeIdentifier,
            rawText: trimmedRaw == trimmed || trimmedRaw?.isEmpty == true ? nil : trimmedRaw
        )
        transcripts = Array(([transcript] + transcripts).prefix(Self.capacity))
        save()
        return transcript
    }

    func delete(_ transcript: DictationTranscript) {
        transcripts.removeAll { $0.id == transcript.id }
        save()
    }

    func clear() {
        transcripts.removeAll()
        save()
    }

    func eraseAll() throws {
        transcripts.removeAll()
        persistenceError = nil
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        try FileManager.default.removeItem(at: storageURL)
    }

    func retryPersistence() {
        save()
    }

    static func matching(_ transcripts: [DictationTranscript], query: String) -> [DictationTranscript] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return transcripts }
        return transcripts.filter { $0.text.localizedCaseInsensitiveContains(needle) }
    }

    private func save() {
        do {
            let encoded = try JSONEncoder().encode(transcripts)
            try encoded.write(to: storageURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = "Dictation transcripts could not be saved. Your recent transcripts are still available until Voqora quits."
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        guard let data = try? Data(contentsOf: storageURL) else {
            persistenceError = "Saved dictation transcripts could not be loaded. New dictation still works."
            return
        }
        do {
            let decoded = try JSONDecoder().decode([LossyTranscript].self, from: data).compactMap(\.transcript)
            transcripts = Array(decoded.prefix(Self.capacity))
        } catch {
            let backup = storageURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: storageURL, to: backup)
            persistenceError = "Saved dictation transcripts could not be loaded. New dictation still works."
        }
    }
}
