import Foundation

protocol PronunciationServing {
    func list(scope: PronunciationScope?) async throws -> PronunciationList
    func create(_ request: PronunciationRequest) async throws -> PronunciationEntry
    func update(id: String, with request: PronunciationRequest) async throws -> PronunciationEntry
    func delete(id: String) async throws
    func test(text: String, bookID: String?) async throws -> PronunciationTestResult
}

final class PronunciationService: PronunciationServing {
    private let client: BackendAPIClient

    init(client: BackendAPIClient? = nil) {
        self.client = client ?? BackendAPIClient()
    }

    func list(scope: PronunciationScope?) async throws -> PronunciationList {
        let query = scope.map { [URLQueryItem(name: "scope", value: $0.rawValue)] } ?? []
        return try await client.get(PronunciationList.self, path: "pronunciations", query: query)
    }

    func create(_ request: PronunciationRequest) async throws -> PronunciationEntry {
        try await client.send(PronunciationEntry.self, path: "pronunciations", method: "POST", body: request)
    }

    func update(id: String, with request: PronunciationRequest) async throws -> PronunciationEntry {
        let path = try Self.path(for: id)
        return try await client.send(PronunciationEntry.self, path: path, method: "PUT", body: request)
    }

    func delete(id: String) async throws {
        let path = try Self.path(for: id)
        try await client.delete(path: path)
    }

    func test(text: String, bookID: String?) async throws -> PronunciationTestResult {
        let body = PronunciationTestRequest(text: text, bookID: bookID.flatMap { PronunciationRules.isHexID($0) ? $0 : nil })
        return try await client.send(PronunciationTestResult.self, path: "pronunciations/test", method: "POST", body: body, timeout: 30)
    }

    static func path(for id: String) throws -> String {
        guard PronunciationRules.isHexID(id) else {
            throw BackendAPIError.rejected(statusCode: 400, message: "That pronunciation can't be found.")
        }
        return "pronunciations/\(id)"
    }
}
