import Foundation

protocol SpeechEngineServing {
    func list() async throws -> [SpeechEngine]
    func install(id: String) async throws -> SpeechEngine
    func uninstall(id: String) async throws -> SpeechEngine
}

final class SpeechEngineService: SpeechEngineServing {
    private let client: BackendAPIClient

    init(client: BackendAPIClient? = nil) {
        self.client = client ?? BackendAPIClient()
    }

    func list() async throws -> [SpeechEngine] {
        try await client.get(SpeechEngineList.self, path: "engine").engines
    }

    func install(id: String) async throws -> SpeechEngine {
        try await client.send(SpeechEngine.self, path: Self.path(for: id, action: "install"), method: "POST", body: EmptyBody())
    }

    func uninstall(id: String) async throws -> SpeechEngine {
        try await client.delete(path: Self.path(for: id))
        guard let engine = try await list().first(where: { $0.id == id }) else {
            throw BackendAPIError.invalidResponse
        }
        return engine
    }

    static func path(for id: String, action: String? = nil) -> String {
        let segment = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let encoded = id.addingPercentEncoding(withAllowedCharacters: segment) ?? id
        return ["engine", encoded, action].compactMap(\.self).joined(separator: "/")
    }

    private struct EmptyBody: Encodable {}
}
