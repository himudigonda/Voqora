import Combine
import Foundation

enum PronunciationFilter: Hashable {
    case all
    case scope(PronunciationScope)

    func includes(_ entry: PronunciationEntry) -> Bool {
        switch self {
        case .all: true
        case let .scope(scope): entry.scopeValue == scope
        }
    }
}

struct PronunciationImportSummary: Equatable {
    var added = 0
    var skipped = 0
    var invalid = 0
    var limitReached = false

    var message: String {
        var parts = ["Imported \(added) \(added == 1 ? "pronunciation" : "pronunciations")."]
        if skipped > 0 {
            parts.append("Skipped \(skipped) already in your dictionary.")
        }
        if invalid > 0 {
            parts.append("\(invalid) \(invalid == 1 ? "entry wasn't" : "entries weren't") valid.")
        }
        if limitReached {
            parts.append("Your dictionary is full at \(PronunciationRules.maxEntries) entries.")
        }
        return parts.joined(separator: " ")
    }
}

final class PronunciationStore: ObservableObject {
    @Published private(set) var entries: [PronunciationEntry] = []
    @Published private(set) var maxEntries = PronunciationRules.maxEntries
    @Published private(set) var state: VoicesLoadState = .idle
    @Published var searchText = ""
    @Published var filter: PronunciationFilter
    @Published private(set) var testResult: PronunciationTestResult?
    @Published private(set) var testError: String?
    @Published private(set) var isTesting = false

    let bookID: String?
    private let service: any PronunciationServing
    private var refreshGeneration = 0
    private var testGeneration = 0

    init(service: (any PronunciationServing)? = nil, bookID: String? = nil) {
        self.service = service ?? PronunciationService()
        let validBookID = bookID.flatMap { PronunciationRules.isHexID($0) ? $0 : nil }
        self.bookID = validBookID
        filter = validBookID.map { PronunciationFilter.scope(.book($0)) } ?? .all
    }

    var visibleEntries: [PronunciationEntry] {
        entries
            .filter { filter.includes($0) && $0.matches(query: searchText) }
            .sorted { $0.match.localizedCaseInsensitiveCompare($1.match) == .orderedAscending }
    }

    var defaultScope: PronunciationScope {
        if case let .scope(scope) = filter {
            return scope
        }
        return .global
    }

    var isFull: Bool {
        entries.count >= maxEntries
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        if state != .loaded {
            state = .loading
        }
        do {
            let list = try await service.list(scope: nil)
            guard generation == refreshGeneration else { return }
            entries = list.entries
            maxEntries = list.maxEntries
            state = .loaded
        } catch {
            guard generation == refreshGeneration else { return }
            VoqoraLog.warn("PronunciationStore", "Pronunciations failed to load", ["status": BackendAPIError.logLabel(for: error)])
            if state != .loaded {
                state = .failed(error.localizedDescription)
            }
        }
    }

    @discardableResult
    func save(_ draft: PronunciationDraft, editing id: String?) async throws -> PronunciationEntry {
        if let message = draft.validationMessage {
            throw UserFacingError(message: message)
        }
        if id == nil, isFull {
            throw UserFacingError(message: "You can save up to \(maxEntries) pronunciations.")
        }
        let saved: PronunciationEntry
        do {
            if let id {
                saved = try await service.update(id: id, with: draft.request)
            } else {
                saved = try await service.create(draft.request)
            }
        } catch {
            VoqoraLog.warn("PronunciationStore", "Pronunciation save failed", ["status": BackendAPIError.logLabel(for: error)])
            throw Self.friendly(error)
        }
        upsert(saved)
        VoqoraLog.info("PronunciationStore", id == nil ? "Pronunciation created" : "Pronunciation updated")
        return saved
    }

    func delete(_ entry: PronunciationEntry) async throws {
        do {
            try await service.delete(id: entry.id)
        } catch let error as BackendAPIError where error.statusCode == 404 {
            VoqoraLog.info("PronunciationStore", "Pronunciation was already deleted")
        } catch {
            VoqoraLog.warn("PronunciationStore", "Pronunciation delete failed", ["status": BackendAPIError.logLabel(for: error)])
            throw error
        }
        entries.removeAll { $0.id == entry.id }
        refreshGeneration &+= 1
    }

    func runTest(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        testGeneration &+= 1
        let generation = testGeneration
        testError = nil
        guard !trimmed.isEmpty else {
            testResult = nil
            testError = "Type a sentence to test."
            return
        }
        guard trimmed.count <= PronunciationRules.maxTestTextLength else {
            testResult = nil
            testError = "Test up to \(PronunciationRules.maxTestTextLength) characters at a time."
            return
        }
        isTesting = true
        defer {
            if generation == testGeneration {
                isTesting = false
            }
        }
        do {
            let result = try await service.test(text: trimmed, bookID: bookID)
            guard generation == testGeneration else { return }
            testResult = result
        } catch {
            guard generation == testGeneration else { return }
            VoqoraLog.warn("PronunciationStore", "Pronunciation test failed", ["status": BackendAPIError.logLabel(for: error)])
            testResult = nil
            testError = error.localizedDescription
        }
    }

    func exportData() throws -> Data {
        let exportable = entries.filter { filter.includes($0) }
        guard !exportable.isEmpty else {
            throw UserFacingError(message: "There are no pronunciations to export yet.")
        }
        return try PronunciationTransferFile(entries: exportable).encoded()
    }

    func importFile(_ data: Data) async throws -> PronunciationImportSummary {
        let file = try PronunciationTransferFile.decode(data)
        var summary = PronunciationImportSummary()
        for draft in file.drafts(in: defaultScope) {
            guard draft.isValid else {
                summary.invalid += 1
                continue
            }
            guard !isFull else {
                summary.limitReached = true
                break
            }
            do {
                let saved = try await service.create(draft.request)
                upsert(saved)
                summary.added += 1
            } catch let error as BackendAPIError where error.statusCode == 409 {
                summary.skipped += 1
            } catch let error as BackendAPIError where error.statusCode == 422 {
                summary.invalid += 1
            } catch {
                VoqoraLog.warn("PronunciationStore", "Pronunciation import stopped", ["status": BackendAPIError.logLabel(for: error), "added": "\(summary.added)"])
                throw Self.friendly(error)
            }
        }
        VoqoraLog.info("PronunciationStore", "Pronunciations imported", ["added": "\(summary.added)", "skipped": "\(summary.skipped)"])
        return summary
    }

    private func upsert(_ entry: PronunciationEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        refreshGeneration &+= 1
    }

    static func friendly(_ error: Error) -> Error {
        guard let apiError = error as? BackendAPIError, apiError.statusCode == 404 else { return error }
        return UserFacingError(message: "That book or pronunciation no longer exists. Refresh and try again.")
    }
}
